#include "core/Diagnostics.h"
#include "core/Model.h"
#include "core/Persistence.h"
#include "core/Recovery.h"
#include "core/Solar.h"
#include "platform/Backlight.h"

#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QTemporaryDir>
#include <QtTest>

#include <cmath>
#include <sys/stat.h>

using namespace ember;

class DomainTests final : public QObject {
  Q_OBJECT

private slots:
  void defaultsAndValidation();
  void colorCurveAndMatrix();
  void quantizationAndNoCompounding();
  void settingsPersistenceAndFutureSchema();
  void recoveryJournalIsFailClosed();
  void solarBoundariesAndPolarConditions();
  void recoveryDecisionPreservesUserChanges();
  void backlightCapabilityIsUnambiguous();
  void diagnosticsAreSanitized();
};

void DomainTests::defaultsAndValidation() {
  const Settings defaults = Settings::defaults();
  QCOMPARE(defaults.warmth, 0.62);
  QCOMPARE(defaults.brightness, 0.75);
  QVERIFY(!defaults.filterEnabled);
  QVERIFY(!defaults.sunScheduleEnabled);
  QVERIFY(defaults.validate());

  Settings invalid = defaults;
  invalid.warmth = std::numeric_limits<double>::quiet_NaN();
  QString reason;
  QVERIFY(!invalid.validate(&reason));
  QVERIFY(!reason.isEmpty());
  invalid = defaults;
  invalid.brightness = 0.09;
  QVERIFY(!invalid.validate(&reason));
  invalid = defaults;
  invalid.location = Coordinate{0.0, 0.0};
  QVERIFY(invalid.validate());
}

void DomainTests::colorCurveAndMatrix() {
  const ColorGains neutral = gainsForWarmth(0.0);
  QCOMPARE(neutral, (ColorGains{1.0F, 1.0F, 1.0F}));
  const ColorGains pureRed = gainsForWarmth(1.0);
  QCOMPARE(pureRed, (ColorGains{1.0F, 0.0F, 0.0F}));
  QVERIFY(!approximateKelvin(1.0).has_value());
  const ColorGains evening = gainsForWarmth(0.62);
  QVERIFY(evening.red >= evening.green);
  QVERIFY(evening.green >= evening.blue);
  const ColorGains pureRedTail = gainsForWarmth(0.9);
  QVERIFY(pureRedTail.green > 0.0F);
  QVERIFY(pureRedTail.blue >= 0.0F);

  Settings settings;
  settings.warmth = 0.62;
  settings.brightness = 0.75;
  const ColorMatrix matrix = matrixFor(settings);
  QVERIFY(finiteNonNegativeMatrix(matrix));
  QCOMPARE(matrix.values[1], 0.0);
  QCOMPARE(matrix.values[3], 0.0);
  QCOMPARE(matrix.values[8], static_cast<double>(gainsForWarmth(0.62).blue) * 0.75);
}

void DomainTests::quantizationAndNoCompounding() {
  for (const double warmth : {0.0, 0.01, 0.2, 0.62, 0.819999, 0.82, 0.820001, 0.9, 0.99, 1.0}) {
    for (const double brightness : {0.1, 0.75, 1.0}) {
      Settings settings;
      settings.warmth = warmth;
      settings.brightness = brightness;
      const ColorMatrix matrix = matrixFor(settings);
      QVERIFY(finiteNonNegativeMatrix(matrix));
      for (const double value : matrix.values) QVERIFY(std::isfinite(value));
      for (const double value : matrix.values) {
        const double reconstructed = fixed24_8ToDouble(fixed24_8(value));
        QVERIFY(std::abs(reconstructed - value) <= (1.0 / 256.0));
      }
    }
  }
  Settings settings;
  settings.warmth = 0.73;
  settings.brightness = 0.42;
  const ColorMatrix first = matrixFor(settings);
  const ColorMatrix second = matrixFor(settings);
  QCOMPARE(first, second);
  QCOMPARE(fixed24_8(0.0), 0);
  QCOMPARE(fixed24_8ToDouble(fixed24_8(1.0)), 1.0);
}

void DomainTests::settingsPersistenceAndFutureSchema() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  Paths paths;
  paths.configDir = temporary.filePath(QStringLiteral("config/project-ember"));
  paths.stateDir = temporary.filePath(QStringLiteral("state/project-ember"));
  paths.runtimeDir = temporary.filePath(QStringLiteral("run/project-ember"));
  paths.settingsFile = QDir(paths.configDir).filePath(QStringLiteral("settings.json"));
  paths.recoveryFile = QDir(paths.stateDir).filePath(QStringLiteral("recovery.json"));
  paths.safetyLatchFile = QDir(paths.stateDir).filePath(QStringLiteral("automation-paused"));
  paths.guardianFile = QDir(paths.runtimeDir).filePath(QStringLiteral("guardian.json"));
  SettingsStore store(paths);
  Settings settings = Settings::defaults();
  settings.location = Coordinate{0.0, 0.0};
  QString error;
  QVERIFY(store.save(settings, &error));
  const SettingsLoadResult loaded = store.load();
  QCOMPARE(loaded.kind, LoadKind::Loaded);
  QCOMPARE(loaded.settings, settings);
  QVERIFY((QFileInfo(paths.settingsFile).permissions() & QFileDevice::WriteOther) == 0);

  QFile future(paths.settingsFile);
  QVERIFY(future.open(QIODevice::WriteOnly | QIODevice::Truncate));
  future.write("{\"schemaVersion\":999}");
  future.close();
  QCOMPARE(store.load().kind, LoadKind::FutureSchema);
}

void DomainTests::recoveryJournalIsFailClosed() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  Paths paths;
  paths.configDir = temporary.filePath(QStringLiteral("config"));
  paths.stateDir = temporary.filePath(QStringLiteral("state/project-ember"));
  paths.runtimeDir = temporary.filePath(QStringLiteral("run"));
  paths.settingsFile = temporary.filePath(QStringLiteral("settings.json"));
  paths.recoveryFile = QDir(paths.stateDir).filePath(QStringLiteral("recovery.json"));
  paths.safetyLatchFile = temporary.filePath(QStringLiteral("paused"));
  paths.guardianFile = temporary.filePath(QStringLiteral("guardian.json"));
  RecoveryJournal journal(paths);
  QString error;
  QVERIFY(ensurePrivateDirectory(paths.stateDir, &error));
  QFile corrupt(paths.recoveryFile);
  QVERIFY(corrupt.open(QIODevice::WriteOnly));
  corrupt.write("not-json");
  corrupt.close();
  QVERIFY(corrupt.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner));
  QCOMPARE(journal.load().kind, LoadKind::Corrupt);
  QString quarantined;
  QVERIFY(journal.quarantine(&quarantined, &error));
  QVERIFY(QFileInfo::exists(quarantined));
  QVERIFY(!journal.exists());

  RecoveryRecord record;
  record.createdAtMs = 1234;
  record.hardware = HardwareRecord{QStringLiteral("device-id"), QStringLiteral("/tmp/device"), QStringLiteral("boot"), 10, 100, 100, true, {}};
  QVERIFY(journal.save(record, &error));
  const RecoveryLoadResult loaded = journal.load();
  QCOMPARE(loaded.kind, LoadKind::Loaded);
  QVERIFY(loaded.record.hardware.has_value());
  QVERIFY(journal.clear(&error));
  QVERIFY(!journal.exists());
}

void DomainTests::solarBoundariesAndPolarConditions() {
  QTimeZone utc("UTC");
  const Coordinate equator{0.0, 0.0};
  const QDateTime noon(QDate(2026, 3, 20), QTime(12, 0), utc);
  const SolarDay equinox = solarDay(noon, equator, utc);
  QCOMPARE(equinox.condition, SolarDayCondition::Normal);
  QVERIFY(equinox.sunrise.time().hour() >= 5 && equinox.sunrise.time().hour() <= 7);
  QVERIFY(equinox.sunset.time().hour() >= 17 && equinox.sunset.time().hour() <= 19);
  QVERIFY(!solarSchedule(noon, equator, utc).isNight);
  QVERIFY(solarSchedule(noon, equator, utc).nextEvent.has_value());
  QCOMPARE(solarSchedule(noon, equator, utc).nextEvent->kind, SolarEventKind::Sunset);

  const Coordinate arctic{78.2, 15.6};
  const QDateTime summer(QDate(2026, 6, 21), QTime(12, 0), utc);
  const QDateTime winter(QDate(2026, 12, 21), QTime(12, 0), utc);
  QCOMPARE(solarDay(summer, arctic, utc).condition, SolarDayCondition::SunAlwaysAbove);
  QCOMPARE(solarDay(winter, arctic, utc).condition, SolarDayCondition::SunAlwaysBelow);
  QVERIFY(solarSchedule(summer, arctic, utc).nextEvent.has_value());
  QVERIFY(solarSchedule(winter, arctic, utc).nextEvent.has_value());

  QTimeZone berlin("Europe/Berlin");
  const QDateTime dst(QDate(2026, 3, 29), QTime(12, 0), berlin);
  const SolarDay dstDay = solarDay(dst, Coordinate{52.5, 13.4}, berlin);
  QVERIFY(dstDay.sunrise.date() == dst.date());
  QVERIFY(dstDay.sunset.date() == dst.date());
}

void DomainTests::recoveryDecisionPreservesUserChanges() {
  HardwareRecord record{QStringLiteral("id"), QStringLiteral("/tmp/device"), QStringLiteral("boot"), 40, 100, 100, true, {}};
  QCOMPARE(decideHardwareRestore(record, 100, QStringLiteral("boot")), HardwareRestoreDecision::Restore);
  QCOMPARE(decideHardwareRestore(record, 40, QStringLiteral("boot")), HardwareRestoreDecision::NothingToRestore);
  QCOMPARE(decideHardwareRestore(record, 70, QStringLiteral("boot")), HardwareRestoreDecision::PreserveUncertain);
  QCOMPARE(decideHardwareRestore(record, 100, QStringLiteral("new-boot")), HardwareRestoreDecision::PreserveUncertain);
}

void DomainTests::backlightCapabilityIsUnambiguous() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  const QString root = temporary.filePath(QStringLiteral("backlight"));
  const QString physical = temporary.filePath(QStringLiteral("intel_edp_backlight"));
  QVERIFY(QDir().mkpath(physical));
  auto write = [](const QString &path, const QByteArray &value) {
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(value);
    file.close();
  };
  write(QDir(physical).filePath(QStringLiteral("max_brightness")), "100");
  write(QDir(physical).filePath(QStringLiteral("brightness")), "40");
  write(QDir(physical).filePath(QStringLiteral("type")), "raw");
  QVERIFY(QDir().mkpath(root));
  QVERIFY(QDir().mkpath(root));
  QVERIFY(QDir().rename(physical, QDir(root).filePath(QStringLiteral("intel_edp_backlight"))));
  qputenv("EMBER_BACKLIGHT_ROOT", root.toUtf8());
  Paths paths;
  paths.runtimeDir = temporary.filePath(QStringLiteral("run"));
  paths.guardianFile = QDir(paths.runtimeDir).filePath(QStringLiteral("guardian.json"));
  BacklightController controller(paths);
  const BacklightCapability capability = controller.probe();
  QVERIFY2(capability.available, qPrintable(capability.reason));
  QCOMPARE(capability.maximum, 100);
  QCOMPARE(capability.brightness, 40);
  qunsetenv("EMBER_BACKLIGHT_ROOT");
}

void DomainTests::diagnosticsAreSanitized() {
  QVariantMap source;
  source.insert(QStringLiteral("location"), QStringLiteral("28.1,-16.2"));
  source.insert(QStringLiteral("home"), QStringLiteral("/home/user"));
  source.insert(QStringLiteral("rawSerials"), QStringLiteral("secret"));
  source.insert(QStringLiteral("requestProcessed"), true);
  const QVariantMap sanitized = sanitizedDiagnostics(source);
  QVERIFY(!sanitized.contains(QStringLiteral("location")));
  QVERIFY(!sanitized.contains(QStringLiteral("home")));
  QVERIFY(!sanitized.contains(QStringLiteral("rawSerials")));
  QCOMPARE(sanitized.value(QStringLiteral("pixelsVerified")).toBool(), false);
}

QTEST_APPLESS_MAIN(DomainTests)

#include "DomainTests.moc"
