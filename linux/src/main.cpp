#include "AppController.h"
#include "Ipc.h"
#include "core/Persistence.h"
#include "core/Recovery.h"
#include "platform/Backlight.h"
#include "platform/WaylandBackend.h"

#include <QApplication>
#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QJsonDocument>
#include <QLockFile>
#include <QProcess>
#include <QSysInfo>
#include <QTextStream>
#include <QThread>

#include <iostream>
#include <cmath>
#include <unistd.h>

namespace {

QString json(const QVariantMap &value) {
  return QString::fromUtf8(QJsonDocument::fromVariant(value).toJson(QJsonDocument::Indented));
}

int callResident(const QString &method, const QVariantList &args = {});

QString systemctlExecutable() {
  const QByteArray override = qgetenv("EMBER_SYSTEMCTL");
  return override.isEmpty() ? QStringLiteral("systemctl") : QString::fromLocal8Bit(override);
}

bool isolatedRootTestAllowed() {
  if (qgetenv("EMBER_TEST_ALLOW_ROOT") != QByteArray("1")) return false;
  const QString backlightRoot = QDir::cleanPath(QString::fromUtf8(qgetenv("EMBER_BACKLIGHT_ROOT")));
  return !backlightRoot.isEmpty()
      && backlightRoot.startsWith(QDir::cleanPath(QDir::tempPath()) + QLatin1Char('/'));
}

void usage(QTextStream &out) {
  out << "project-ember [settings|on|off|toggle|preset neutral|evening|pure-red|warmth 0..100|brightness 10..100|status --json|doctor --json|resume-automation|resolve-recovery keep-current|discard-unreadable|resolve-settings replace|restore|quit]\n";
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
  result.insert(QStringLiteral("buildArchitecture"), QSysInfo::buildCpuArchitecture());
  result.insert(QStringLiteral("currentArchitecture"), QSysInfo::currentCpuArchitecture());
  result.insert(QStringLiteral("kernelType"), QSysInfo::kernelType());
  result.insert(QStringLiteral("kernelVersion"), QSysInfo::kernelVersion());
  result.insert(QStringLiteral("productType"), QSysInfo::productType());
  result.insert(QStringLiteral("productVersion"), QSysInfo::productVersion());
  result.insert(QStringLiteral("qtRuntimeVersion"), QString::fromLatin1(qVersion()));
  result.insert(QStringLiteral("waylandSessionEnvironment"), !qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY"));
  result.insert(QStringLiteral("settingsLoad"), settings.kind == ember::LoadKind::Loaded ? QStringLiteral("loaded") :
      settings.kind == ember::LoadKind::NoFile ? QStringLiteral("defaults") :
      settings.kind == ember::LoadKind::FutureSchema ? QStringLiteral("future_schema") :
      settings.kind == ember::LoadKind::Corrupt ? QStringLiteral("corrupt") : QStringLiteral("io_failure"));
  result.insert(QStringLiteral("filterEnabled"), settings.settings.filterEnabled);
  result.insert(QStringLiteral("desiredFilterEnabled"), settings.settings.filterEnabled);
  result.insert(QStringLiteral("effectiveFilterEnabled"), false);
  result.insert(QStringLiteral("runtimeState"), QStringLiteral("not_running"));
  result.insert(QStringLiteral("protocolOwnership"), QStringLiteral("none"));
  result.insert(QStringLiteral("warmth"), settings.settings.warmth);
  result.insert(QStringLiteral("brightness"), settings.settings.brightness);
  result.insert(QStringLiteral("sunScheduleEnabled"), settings.settings.sunScheduleEnabled);
  result.insert(QStringLiteral("recoveryLoad"), recovery.kind == ember::LoadKind::Loaded ? QStringLiteral("loaded") :
      recovery.kind == ember::LoadKind::NoFile ? QStringLiteral("none") :
      recovery.kind == ember::LoadKind::FutureSchema ? QStringLiteral("future_schema") :
      recovery.kind == ember::LoadKind::Corrupt ? QStringLiteral("corrupt") : QStringLiteral("io_failure"));
  result.insert(QStringLiteral("recoveryPending"), recovery.kind != ember::LoadKind::NoFile &&
      (recovery.kind != ember::LoadKind::Loaded || ember::recoveryRecordHasPendingFields(recovery.record)));
  result.insert(QStringLiteral("backlightAvailable"), capability.available);
  result.insert(QStringLiteral("backlightActualReadbackAvailable"), capability.actualBrightnessAvailable);
  result.insert(QStringLiteral("backlightReason"), capability.available ? QString() : capability.reason);
  result.insert(QStringLiteral("automaticBrightnessAvailable"), capability.automaticBrightnessAvailable);
  result.insert(QStringLiteral("automaticBrightnessReason"), capability.automaticBrightnessAvailable
      ? QString() : capability.automaticBrightnessReason);
  result.insert(QStringLiteral("pixelsVerified"), false);
  result.insert(QStringLiteral("requestProcessed"), false);
  result.insert(QStringLiteral("opticalReadback"), QStringLiteral("unavailable; probe did not bind a CTM manager"));
  return result;
}

QVariantMap readOnlySystemProbe() {
  QVariantMap result = localReadOnlyStatus();
  result.insert(QStringLiteral("source"), QStringLiteral("read-only local and Wayland registry probe"));
  ember::WaylandBackend backend;
  QString capabilityReason;
  QObject::connect(&backend, &ember::WaylandBackend::capabilityChanged,
                   [&result, &capabilityReason](bool available, int version, int count, const QString &reason) {
    result.insert(QStringLiteral("waylandAvailable"), available);
    result.insert(QStringLiteral("managerVersion"), version);
    result.insert(QStringLiteral("onlineOutputs"), count);
    capabilityReason = reason;
  });
  backend.probe();
  const QVariantMap snapshot = backend.readOnlyProbeSnapshot();
  for (auto iterator = snapshot.cbegin(); iterator != snapshot.cend(); ++iterator) {
    result.insert(iterator.key(), iterator.value());
  }
  result.insert(QStringLiteral("capabilityReason"), capabilityReason);
  backend.stop();
  return result;
}

int headlessRestore(bool emergencyRestore) {
  const ember::Paths paths = ember::Paths::fromEnvironment();
  QString runtimeError;
  if (!ember::ensurePrivateDirectory(paths.runtimeDir, &runtimeError)) {
    QTextStream(stderr) << "project-ember: recovery ownership could not be established: " << runtimeError << '\n';
    return 1;
  }
  QLockFile controllerLock(paths.controllerLockFile);
  controllerLock.setStaleLockTime(5000);
  if (!controllerLock.tryLock(1000)) {
    QTextStream(stderr) << "project-ember: a resident controller or another recovery helper is still running\n";
    return 1;
  }
  ember::BacklightController backlight(paths);
  const auto finish = [&backlight](int code) {
    if (!backlight.disarmGuardian()) {
      QTextStream(stderr) << "project-ember: could not disarm the recovery guardian\n";
      return 1;
    }
    return code;
  };
  ember::SettingsStore settingsStore(paths);
  const ember::SettingsLoadResult settingsResult = settingsStore.load();
  ember::Settings settings = settingsResult.settings;
  QByteArray cleanMarker;
  QString cleanMarkerReadError;
  bool cleanExit = ember::readRegularPrivateFile(paths.cleanExitFile, &cleanMarker, &cleanMarkerReadError)
      && cleanMarker == QByteArray("clean\n");
  QString cleanMarkerRemoveError;
  const bool cleanMarkerConsumed = ember::removeDurableFile(paths.cleanExitFile, &cleanMarkerRemoveError);
  if (!cleanMarkerConsumed) {
    cleanExit = false;
    QTextStream(stderr) << "project-ember: clean-exit marker could not be consumed safely: "
                        << cleanMarkerRemoveError << '\n';
  }
  if (emergencyRestore) settings.backlightLockEnabled = false;
  const ember::RecoveryJournal journal(paths);
  const ember::RecoveryLoadResult result = journal.load();
  const bool recoveryNeedsPause = result.kind != ember::LoadKind::NoFile;
  const bool canPersistSettings = settingsResult.kind == ember::LoadKind::Loaded || settingsResult.kind == ember::LoadKind::NoFile;
  if (emergencyRestore || !cleanExit || recoveryNeedsPause || !canPersistSettings) settings.filterEnabled = false;
  settings.automationPaused = settings.automationPaused || emergencyRestore || !cleanExit
      || recoveryNeedsPause || !canPersistSettings;
  bool settingsSaveFailed = !canPersistSettings || !cleanMarkerConsumed;
  if (!canPersistSettings) {
    QTextStream(stderr) << "project-ember: unreadable settings were preserved; safety state is carried by the pause latch\n";
  }
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
      return finish(1);
    }
  } else {
    QString latchRemoveError;
    if (!ember::removeDurableFile(paths.safetyLatchFile, &latchRemoveError)) {
      QTextStream(stderr) << "project-ember: could not durably clear automation safety latch: " << latchRemoveError << '\n';
      return finish(1);
    }
  }
  if (result.kind == ember::LoadKind::NoFile) {
    return finish(settingsSaveFailed ? 1 : 0);
  }
  if (result.kind != ember::LoadKind::Loaded) {
    QTextStream(stderr) << "project-ember: recovery remains pending; journal was not treated as empty: " << result.detail << '\n';
    return finish(1);
  }
  ember::RecoveryRecord record = result.record;
  if (!ember::recoveryRecordHasPendingFields(record)) {
    const bool cleared = journal.clear();
    return finish(cleared && !settingsSaveFailed ? 0 : 1);
  }
  QString error;
  if (!backlight.restore(&record, &error)) {
    (void)journal.save(record);
    QTextStream(stderr) << "project-ember: hardware restore remains pending: " << error << '\n';
    return finish(1);
  }
  if (!journal.clear(&error)) {
    QTextStream(stderr) << "project-ember: hardware restored but journal cleanup failed: " << error << '\n';
    return finish(1);
  }
  return finish(settingsSaveFailed ? 1 : 0);
}

int runResident(int argc, char **argv) {
  QApplication app(argc, argv);
  app.setApplicationName(QStringLiteral("Project Ember"));
  app.setQuitOnLastWindowClosed(false);
  if (ember::ipcServiceAvailable()) return 0;
  ember::AppController controller(true);
  QString error;
  if (!controller.start(&error)) {
    QTextStream(stderr) << "project-ember: could not start resident controller: " << error << '\n';
    return 2;
  }
  return app.exec();
}

int openManagedSettings() {
  if (ember::ipcServiceAvailable()) return callResident(QStringLiteral("OpenSettings"));
  QProcess process;
  process.start(systemctlExecutable(), {QStringLiteral("--user"), QStringLiteral("start"),
                                        QStringLiteral("project-ember.service")});
  if (!process.waitForStarted(750) || !process.waitForFinished(2500)) {
    process.kill();
    (void)process.waitForFinished(500);
    QTextStream(stderr) << "project-ember: could not start the managed user service\n";
    return 2;
  }
  if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
    const QString detail = QString::fromLocal8Bit(process.readAllStandardError()).trimmed();
    QTextStream(stderr) << "project-ember: managed user service failed to start"
                        << (detail.isEmpty() ? QString() : QStringLiteral(": %1").arg(detail)) << '\n';
    return 2;
  }
  QElapsedTimer timer;
  timer.start();
  while (timer.elapsed() < 2500) {
    if (ember::ipcServiceAvailable()) return callResident(QStringLiteral("OpenSettings"));
    QThread::msleep(25);
  }
  QTextStream(stderr) << "project-ember: the managed service started but its local D-Bus controller did not appear\n";
  return 2;
}

int quitResidentAndWait() {
  if (!ember::ipcServiceAvailable()) return 0;
  const int requested = callResident(QStringLiteral("Quit"));
  if (requested != 0) return requested;
  QElapsedTimer timer;
  timer.start();
  while (timer.elapsed() < 3500) {
    if (!ember::ipcServiceAvailable()) return 0;
    QThread::msleep(25);
  }
  QTextStream(stderr) << "project-ember: resident did not finish its bounded restore and release before timeout\n";
  return 1;
}

int callResident(const QString &method, const QVariantList &args) {
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
  const bool readOnlyCommand = command == QStringLiteral("status") || command == QStringLiteral("doctor")
      || command == QStringLiteral("--system-probe");
  if (geteuid() == 0 && !readOnlyCommand && !isolatedRootTestAllowed()) {
    QTextStream(stderr) << "project-ember: refusing to run a display-mutating or graphical command as root\n";
    return 2;
  }
  if (command == QStringLiteral("--arm-guardian")) {
    QCoreApplication app(argc, argv);
    ember::BacklightController controller(ember::Paths::fromEnvironment());
    QString error;
    return controller.armGuardian(&error) ? 0 : (QTextStream(stderr) << error << '\n', 1);
  }
  if (command == QStringLiteral("--recover-hardware")) {
    QCoreApplication app(argc, argv);
    return headlessRestore(false);
  }
  if (command == QStringLiteral("--system-probe")) {
    QCoreApplication app(argc, argv);
    QTextStream(stdout) << json(readOnlySystemProbe());
    return 0;
  }
  if (command == QStringLiteral("status") || command == QStringLiteral("doctor")) {
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
    return headlessRestore(true);
  }
  if (command == QStringLiteral("resume-automation")) {
    QCoreApplication app(argc, argv);
    if (!ember::ipcServiceAvailable()) {
      QTextStream(stderr) << "project-ember: no resident controller is running\n";
      return 2;
    }
    return callResident(QStringLiteral("ResumeAutomation"));
  }
  if (command == QStringLiteral("resolve-recovery")) {
    QCoreApplication app(argc, argv);
    if (arguments.size() != 3
        || (arguments.at(2) != QStringLiteral("keep-current")
            && arguments.at(2) != QStringLiteral("discard-unreadable"))) {
      QTextStream(stderr) << "project-ember: resolve-recovery requires `keep-current` or `discard-unreadable`\n";
      return 2;
    }
    if (!ember::ipcServiceAvailable()) {
      QTextStream(stderr) << "project-ember: no resident controller is running\n";
      return 2;
    }
    return callResident(arguments.at(2) == QStringLiteral("keep-current")
        ? QStringLiteral("AcceptCurrentHardwareState")
        : QStringLiteral("DiscardUnreadableRecoveryEvidence"));
  }
  if (command == QStringLiteral("resolve-settings")) {
    QCoreApplication app(argc, argv);
    if (arguments.size() != 3 || arguments.at(2) != QStringLiteral("replace")) {
      QTextStream(stderr) << "project-ember: resolve-settings requires the explicit `replace` choice\n";
      return 2;
    }
    if (!ember::ipcServiceAvailable()) {
      QTextStream(stderr) << "project-ember: no resident controller is running\n";
      return 2;
    }
    return callResident(QStringLiteral("ReplaceUnreadableSettings"));
  }
  if (command == QStringLiteral("quit")) {
    QCoreApplication app(argc, argv);
    return quitResidentAndWait();
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
  if (command == QStringLiteral("settings")) {
    QCoreApplication app(argc, argv);
    return openManagedSettings();
  }
  if (command == QStringLiteral("run") || command == QStringLiteral("--run")) {
    return runResident(argc, argv);
  }
  QTextStream err(stderr);
  usage(err);
  return 2;
}
