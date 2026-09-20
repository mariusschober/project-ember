#include "AppController.h"
#include "Ipc.h"
#include "core/Persistence.h"
#include "platform/Backlight.h"

#include <QApplication>
#include <QCoreApplication>
#include <QFileInfo>
#include <QJsonDocument>
#include <QTextStream>

#include <iostream>
#include <cmath>
#include <unistd.h>

namespace {

QString json(const QVariantMap &value) {
  return QString::fromUtf8(QJsonDocument::fromVariant(value).toJson(QJsonDocument::Indented));
}

void usage(QTextStream &out) {
  out << "project-ember [settings|on|off|toggle|preset neutral|evening|pure-red|warmth 0..100|brightness 10..100|status --json|doctor --json|restore|quit]\n";
}

QVariantMap localReadOnlyStatus() {
  const ember::Paths paths = ember::Paths::fromEnvironment();
  const ember::SettingsStore store(paths);
  const ember::SettingsLoadResult settings = store.load();
  const ember::RecoveryJournal journal(paths);
  const ember::RecoveryLoadResult recovery = journal.load();
  const ember::BacklightController backlight(paths);
  const ember::BacklightCapability capability = backlight.probe();
  QVariantMap result;
  result.insert(QStringLiteral("version"), QStringLiteral("0.1.0-linux-alpha.1"));
  result.insert(QStringLiteral("source"), QStringLiteral("read-only local probe; no Wayland connection opened"));
  result.insert(QStringLiteral("waylandSessionEnvironment"), !qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY"));
  result.insert(QStringLiteral("settingsLoad"), settings.kind == ember::LoadKind::Loaded ? QStringLiteral("loaded") :
      settings.kind == ember::LoadKind::NoFile ? QStringLiteral("defaults") :
      settings.kind == ember::LoadKind::FutureSchema ? QStringLiteral("future_schema") :
      settings.kind == ember::LoadKind::Corrupt ? QStringLiteral("corrupt") : QStringLiteral("io_failure"));
  result.insert(QStringLiteral("filterEnabled"), settings.settings.filterEnabled);
  result.insert(QStringLiteral("warmth"), settings.settings.warmth);
  result.insert(QStringLiteral("brightness"), settings.settings.brightness);
  result.insert(QStringLiteral("sunScheduleEnabled"), settings.settings.sunScheduleEnabled);
  result.insert(QStringLiteral("recoveryLoad"), recovery.kind == ember::LoadKind::Loaded ? QStringLiteral("loaded") :
      recovery.kind == ember::LoadKind::NoFile ? QStringLiteral("none") :
      recovery.kind == ember::LoadKind::FutureSchema ? QStringLiteral("future_schema") :
      recovery.kind == ember::LoadKind::Corrupt ? QStringLiteral("corrupt") : QStringLiteral("io_failure"));
  result.insert(QStringLiteral("recoveryPending"), recovery.kind != ember::LoadKind::NoFile &&
      (recovery.kind != ember::LoadKind::Loaded || recovery.record.hardware.has_value()));
  result.insert(QStringLiteral("backlightAvailable"), capability.available);
  result.insert(QStringLiteral("backlightReason"), capability.available ? QString() : capability.reason);
  result.insert(QStringLiteral("pixelsVerified"), false);
  result.insert(QStringLiteral("opticalReadback"), QStringLiteral("unavailable; probe did not bind a CTM manager"));
  return result;
}

int headlessRestore() {
  const ember::Paths paths = ember::Paths::fromEnvironment();
  ember::SettingsStore settingsStore(paths);
  const ember::SettingsLoadResult settingsResult = settingsStore.load();
  ember::Settings settings = settingsResult.settings;
  const bool cleanExit = QFileInfo::exists(paths.cleanExitFile);
  settings.filterEnabled = false;
  settings.backlightLockEnabled = false;
  const ember::RecoveryJournal journal(paths);
  const ember::RecoveryLoadResult result = journal.load();
  const bool recoveryNeedsPause = result.kind != ember::LoadKind::NoFile;
  const bool canPersistSettings = settingsResult.kind == ember::LoadKind::Loaded || settingsResult.kind == ember::LoadKind::NoFile;
  settings.automationPaused = settings.automationPaused || !cleanExit || recoveryNeedsPause || !canPersistSettings;
  bool settingsSaveFailed = false;
  if (canPersistSettings) {
    QString settingsError;
    if (!settingsStore.save(settings, &settingsError)) {
      settingsSaveFailed = true;
      QTextStream(stderr) << "project-ember: could not save safety settings: " << settingsError << '\n';
    }
  }
  if (settings.automationPaused || settingsSaveFailed) {
    QString latchError;
    if (!ember::writeDurableFile(paths.safetyLatchFile, QByteArray("paused\n"), 0600, &latchError)) {
      QTextStream(stderr) << "project-ember: could not write automation safety latch: " << latchError << '\n';
      return 1;
    }
  } else {
    (void)unlink(paths.safetyLatchFile.toUtf8().constData());
  }
  if (result.kind == ember::LoadKind::NoFile) {
    (void)unlink(paths.cleanExitFile.toUtf8().constData());
    return settingsSaveFailed ? 1 : 0;
  }
  if (result.kind != ember::LoadKind::Loaded) {
    QTextStream(stderr) << "project-ember: recovery remains pending; journal was not treated as empty: " << result.detail << '\n';
    return 1;
  }
  ember::RecoveryRecord record = result.record;
  if (!record.hardware.has_value()) {
    const bool cleared = journal.clear();
    if (cleared) (void)unlink(paths.cleanExitFile.toUtf8().constData());
    return cleared && !settingsSaveFailed ? 0 : 1;
  }
  ember::BacklightController backlight(paths);
  QString error;
  if (!backlight.restore(&record, &error)) {
    record.hardware->unresolved = true;
    record.hardware->error = error;
    (void)journal.save(record);
    QTextStream(stderr) << "project-ember: hardware restore remains pending: " << error << '\n';
    return 1;
  }
  if (!journal.clear(&error)) {
    QTextStream(stderr) << "project-ember: hardware restored but journal cleanup failed: " << error << '\n';
    return 1;
  }
  (void)unlink(paths.cleanExitFile.toUtf8().constData());
  return settingsSaveFailed ? 1 : 0;
}

int runResident(int argc, char **argv) {
  QApplication app(argc, argv);
  app.setApplicationName(QStringLiteral("Project Ember"));
  app.setQuitOnLastWindowClosed(false);
  ember::AppController controller(true);
  QString error;
  if (!controller.start(&error)) {
    QTextStream(stderr) << "project-ember: could not start resident controller: " << error << '\n';
    return 2;
  }
  return app.exec();
}

int callResident(const QString &method, const QVariantList &args = {}) {
  QVariant reply;
  QString error;
  if (!ember::ipcCall(method, args, &reply, &error)) {
    QTextStream(stderr) << "project-ember: " << error << '\n';
    return 2;
  }
  if (reply.isValid() && reply.canConvert<QVariantMap>()) QTextStream(stdout) << json(reply.toMap());
  return 0;
}

} // namespace

int main(int argc, char **argv) {
  QStringList arguments;
  for (int index = 0; index < argc; ++index) arguments.append(QString::fromLocal8Bit(argv[index]));
  const QString command = arguments.size() > 1 ? arguments.at(1) : QStringLiteral("settings");

  if (command == QStringLiteral("--version")) {
    std::cout << "0.1.0-linux-alpha.1\n";
    return 0;
  }
  if (command == QStringLiteral("--help") || command == QStringLiteral("help")) {
    QTextStream(stdout) << "Project Ember — native Linux tray/settings utility\n";
    QTextStream out(stdout);
    usage(out);
    return 0;
  }
  if (command == QStringLiteral("--arm-guardian")) {
    QCoreApplication app(argc, argv);
    ember::BacklightController controller(ember::Paths::fromEnvironment());
    QString error;
    return controller.armGuardian(&error) ? 0 : (QTextStream(stderr) << error << '\n', 1);
  }
  if (command == QStringLiteral("--recover-hardware")) {
    QCoreApplication app(argc, argv);
    return headlessRestore();
  }
  if (command == QStringLiteral("status") || command == QStringLiteral("doctor") || command == QStringLiteral("--system-probe")) {
    QCoreApplication app(argc, argv);
    if (ember::ipcServiceAvailable()) {
      QVariant reply;
      QString error;
      if (!ember::ipcCall(QStringLiteral("GetStatus"), {}, &reply, &error)) {
        QTextStream(stderr) << error << '\n';
        return 2;
      }
      QTextStream(stdout) << json(reply.toMap());
      return 0;
    }
    QTextStream(stdout) << json(localReadOnlyStatus());
    return 0;
  }
  if (command == QStringLiteral("restore")) {
    QCoreApplication app(argc, argv);
    if (ember::ipcServiceAvailable()) return callResident(QStringLiteral("Restore"));
    return headlessRestore();
  }
  if (command == QStringLiteral("quit")) {
    QCoreApplication app(argc, argv);
    if (!ember::ipcServiceAvailable()) return 0;
    return callResident(QStringLiteral("Quit"));
  }
  if (command == QStringLiteral("on") || command == QStringLiteral("off") || command == QStringLiteral("toggle")) {
    QCoreApplication app(argc, argv);
    if (!ember::ipcServiceAvailable()) {
      QTextStream(stderr) << "project-ember: no resident controller is running; use `project-ember settings` or the managed user service\n";
      return 2;
    }
    if (command == QStringLiteral("toggle")) {
      QVariant reply;
      QString error;
      if (!ember::ipcCall(QStringLiteral("GetStatus"), {}, &reply, &error)) {
        QTextStream(stderr) << error << '\n';
        return 2;
      }
      return callResident(QStringLiteral("SetFilterEnabled"), {QVariant(!reply.toMap().value(QStringLiteral("filterEnabled")).toBool())});
    }
    return callResident(QStringLiteral("SetFilterEnabled"), {QVariant(command == QStringLiteral("on"))});
  }
  if (command == QStringLiteral("preset")) {
    QCoreApplication app(argc, argv);
    if (arguments.size() != 3 || !ember::ipcServiceAvailable()) {
      QTextStream(stderr) << "project-ember: `preset` requires a running resident controller and neutral, evening, or pure-red\n";
      return 2;
    }
    return callResident(QStringLiteral("SetPreset"), {arguments.at(2)});
  }
  if (command == QStringLiteral("warmth") || command == QStringLiteral("brightness")) {
    QCoreApplication app(argc, argv);
    if (arguments.size() != 3 || !ember::ipcServiceAvailable()) {
      QTextStream(stderr) << "project-ember: " << command << " requires a running resident controller\n";
      return 2;
    }
    bool ok = false;
    const double value = arguments.at(2).toDouble(&ok);
    const double lower = command == QStringLiteral("warmth") ? 0.0 : 10.0;
    const double upper = 100.0;
    if (!ok || !std::isfinite(value) || value < lower || value > upper) {
      QTextStream(stderr) << "project-ember: value is outside the documented range\n";
      return 2;
    }
    return callResident(command == QStringLiteral("warmth") ? QStringLiteral("SetWarmth") : QStringLiteral("SetBrightness"), {QVariant(value / 100.0)});
  }
  if (command == QStringLiteral("settings") || command == QStringLiteral("run")) {
    return runResident(argc, argv);
  }
  QTextStream err(stderr);
  usage(err);
  return 2;
}
