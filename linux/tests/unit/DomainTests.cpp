#include "core/Diagnostics.h"
#include "core/Model.h"
#include "core/Persistence.h"
#include "core/Recovery.h"
#include "core/Solar.h"
#include "platform/Backlight.h"

#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QScopeGuard>
#include <QTemporaryDir>
#include <QtTest>

#include <cmath>
#include <sys/stat.h>

using namespace ember;

namespace {

Paths pathsFor(const QTemporaryDir &temporary) {
  Paths paths;
  paths.configDir = temporary.filePath(QStringLiteral("config/project-ember"));
  paths.stateDir = temporary.filePath(QStringLiteral("state/project-ember"));
  paths.runtimeDir = temporary.filePath(QStringLiteral("run/project-ember"));
  paths.settingsFile = QDir(paths.configDir).filePath(QStringLiteral("settings.json"));
  paths.recoveryFile = QDir(paths.stateDir).filePath(QStringLiteral("recovery.json"));
  paths.safetyLatchFile = QDir(paths.stateDir).filePath(QStringLiteral("automation-paused"));
  paths.guardianFile = QDir(paths.runtimeDir).filePath(QStringLiteral("guardian.json"));
  paths.cleanExitFile = QDir(paths.runtimeDir).filePath(QStringLiteral("clean-exit"));
  return paths;
}

bool writeTestFile(const QString &path, const QByteArray &data, QFileDevice::Permissions permissions =
                       QFileDevice::ReadOwner | QFileDevice::WriteOwner) {
  if (!QDir().mkpath(QFileInfo(path).absolutePath())) return false;
  QFile file(path);
  if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
  if (file.write(data) != data.size()) return false;
  file.close();
  return QFile::setPermissions(path, permissions);
}

bool createFakeBacklightTree(const QTemporaryDir &temporary, bool automaticBrightness = true,
                             const QString &backlightName = QStringLiteral("intel_backlight")) {
  const QString root = temporary.filePath(QStringLiteral("backlight"));
  const QString drmRoot = temporary.filePath(QStringLiteral("drm"));
  const QString gpu = temporary.filePath(QStringLiteral("devices/gpu0"));
  const QString driver = temporary.filePath(QStringLiteral("drivers/intel_backlight"));
  const QString backlight = QDir(root).filePath(backlightName);
  const QString connector = QDir(drmRoot).filePath(QStringLiteral("card0-eDP-1"));
  if (!QDir().mkpath(backlight) || !QDir().mkpath(gpu) || !QDir().mkpath(driver)
      || !QDir().mkpath(connector)) return false;
  if (!QFile::link(gpu, QDir(backlight).filePath(QStringLiteral("device")))) return false;
  const QString driverLink = QDir(gpu).filePath(QStringLiteral("driver"));
  if (!QFileInfo::exists(driverLink) && !QFile::link(driver, driverLink)) return false;
  const QString connectorDevice = QDir(connector).filePath(QStringLiteral("device"));
  if (!QFileInfo::exists(connectorDevice) && !QFile::link(gpu, connectorDevice)) return false;
  const QString brightnessPath = QDir(backlight).filePath(QStringLiteral("brightness"));
  if (!writeTestFile(QDir(backlight).filePath(QStringLiteral("max_brightness")), "100")
      || !writeTestFile(brightnessPath, "40")
      || !writeTestFile(QDir(backlight).filePath(QStringLiteral("type")), "raw")
      || !writeTestFile(QDir(connector).filePath(QStringLiteral("status")), "connected\n")
      || !writeTestFile(QDir(connector).filePath(QStringLiteral("edid")), QByteArray::fromHex("00ffffffffffff0010ac123456789abc"))) {
    return false;
  }
  if (!QFile::link(brightnessPath, QDir(backlight).filePath(QStringLiteral("actual_brightness")))) return false;
  return !automaticBrightness
      || writeTestFile(QDir(backlight).filePath(QStringLiteral("auto_brightness")), "1");
}

} // namespace

class DomainTests final : public QObject {
  Q_OBJECT

private slots:
  void defaultsAndValidation();
  void colorCurveAndMatrix();
  void colorCurveMatchesPinnedMacFixtures();
  void quantizationAndNoCompounding();
  void settingsPersistenceAndFutureSchema();
  void settingsRejectUnsafeAndOutOfRangeInputs();
  void persistenceFaultInjectionFailsClosed();
  void recoveryJournalIsFailClosed();
  void unreadableRecoveryRequiresExplicitDiscard();
  void solarBoundariesAndPolarConditions();
  void solarAcrossTimezonesAndCalendarEdges();
  void recoveryDecisionPreservesUserChanges();
  void backlightCapabilityIsUnambiguous();
  void backlightRestoresFieldsIndependently();
  void guardianRequiresCurrentSupervisedInvocation();
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
  invalid.brightness = std::numeric_limits<double>::infinity();
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

void DomainTests::colorCurveMatchesPinnedMacFixtures() {
  QFile file(QStringLiteral(EMBER_FIXTURE_DIR "/color-curve-mac-4197393.json"));
  QVERIFY2(file.open(QIODevice::ReadOnly), qPrintable(file.errorString()));
  const QJsonDocument document = QJsonDocument::fromJson(file.readAll());
  QVERIFY(document.isObject());
  const QJsonObject root = document.object();
  QCOMPARE(root.value(QStringLiteral("referenceCommit")).toString(),
           QStringLiteral("41973930103c5c12c5c04715f4a1943ff759628d"));
  const QJsonArray rows = root.value(QStringLiteral("rows")).toArray();
  QCOMPARE(rows.size(), 30);
  for (const QJsonValue &rowValue : rows) {
    const QJsonObject row = rowValue.toObject();
    const double warmth = row.value(QStringLiteral("warmth")).toDouble();
    const double brightness = row.value(QStringLiteral("brightness")).toDouble();
    const QJsonArray expectedGains = row.value(QStringLiteral("gains")).toArray();
    const QJsonArray expectedDiagonal = row.value(QStringLiteral("matrixDiagonal")).toArray();
    QCOMPARE(expectedGains.size(), 3);
    QCOMPARE(expectedDiagonal.size(), 3);
    const ColorGains gains = gainsForWarmth(warmth);
    const std::array<double, 3> actualGains = {
        static_cast<double>(gains.red), static_cast<double>(gains.green), static_cast<double>(gains.blue)};
    Settings settings;
    settings.warmth = warmth;
    settings.brightness = brightness;
    const ColorMatrix matrix = matrixFor(settings);
    const std::array<double, 3> actualDiagonal = {matrix.values[0], matrix.values[4], matrix.values[8]};
    for (int channel = 0; channel < 3; ++channel) {
      QVERIFY(std::abs(actualGains[static_cast<size_t>(channel)] - expectedGains.at(channel).toDouble()) <= 1e-5);
      QVERIFY(std::abs(actualDiagonal[static_cast<size_t>(channel)] - expectedDiagonal.at(channel).toDouble()) <= 1e-5);
    }
  }
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

void DomainTests::settingsRejectUnsafeAndOutOfRangeInputs() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  const Paths paths = pathsFor(temporary);
  SettingsStore store(paths);
  QVERIFY(writeTestFile(paths.settingsFile, "{\"schemaVersion\":1}"));
  const SettingsLoadResult defaults = store.load();
  QCOMPARE(defaults.kind, LoadKind::Loaded);
  QCOMPARE(defaults.settings, Settings::defaults());

  QVERIFY(writeTestFile(paths.settingsFile, "{\"schemaVersion\":1,\"warmth\":1.1}"));
  QCOMPARE(store.load().kind, LoadKind::Corrupt);
  QVERIFY(writeTestFile(paths.settingsFile, "{\"schemaVersion\":1,\"brightness\":0.09}"));
  QCOMPARE(store.load().kind, LoadKind::Corrupt);
  QVERIFY(writeTestFile(paths.settingsFile, "{\"schemaVersion\":\"1\"}"));
  QCOMPARE(store.load().kind, LoadKind::Corrupt);
  QVERIFY(writeTestFile(paths.settingsFile,
                        "{\"schemaVersion\":1,\"location\":{\"latitude\":10.05,\"longitude\":-16.25}}"));
  const SettingsLoadResult rounded = store.load();
  QCOMPARE(rounded.kind, LoadKind::Loaded);
  QVERIFY(rounded.settings.location.has_value());
  QCOMPARE(rounded.settings.location->latitude, 10.1);
  QCOMPARE(rounded.settings.location->longitude, -16.3);

  QVERIFY(writeTestFile(paths.settingsFile, QByteArray((1024 * 1024) + 1, 'x')));
  QCOMPARE(store.load().kind, LoadKind::IoFailure);

  QVERIFY(QFile::remove(paths.settingsFile));
  const QString target = temporary.filePath(QStringLiteral("target.json"));
  QVERIFY(writeTestFile(target, "{}"));
  QVERIFY(QFile::link(target, paths.settingsFile));
  QCOMPARE(store.load().kind, LoadKind::IoFailure);
}

void DomainTests::persistenceFaultInjectionFailsClosed() {
  const QList<QByteArray> stages = {"directory", "temp", "write", "file_fsync", "rename", "directory_fsync"};
  for (const QByteArray &stage : stages) {
    QTemporaryDir temporary;
    QVERIFY(temporary.isValid());
    const Paths paths = pathsFor(temporary);
    SettingsStore store(paths);
    qputenv("EMBER_TEST_PERSISTENCE_FAIL", stage);
    const auto resetFailure = qScopeGuard([] { qunsetenv("EMBER_TEST_PERSISTENCE_FAIL"); });
    QString error;
    QVERIFY2(!store.save(Settings::defaults(), &error), stage.constData());
    QVERIFY(!error.isEmpty());
    if (stage != QByteArray("directory_fsync")) QVERIFY(!QFileInfo::exists(paths.settingsFile));
  }

  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  const Paths paths = pathsFor(temporary);
  RecoveryJournal journal(paths);
  RecoveryRecord record;
  record.createdAtMs = 1;
  QString error;
  QVERIFY(journal.save(record, &error));
  qputenv("EMBER_TEST_PERSISTENCE_FAIL", "clear");
  const bool clearFailed = !journal.clear(&error);
  qunsetenv("EMBER_TEST_PERSISTENCE_FAIL");
  QVERIFY(clearFailed);
  QVERIFY(journal.exists());
  QVERIFY(journal.clear(&error));
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
  QVERIFY(writeTestFile(paths.recoveryFile,
      "{\"schemaVersion\":1,\"appVersion\":\"legacy\",\"createdAtMs\":1,"
      "\"hardware\":{\"deviceId\":\"legacy-id\",\"devicePath\":\"/tmp/legacy\","
      "\"bootIdHash\":\"boot\",\"originalBrightness\":10,\"lastWrittenBrightness\":100,"
      "\"maximumBrightness\":100}}"));
  const RecoveryLoadResult migrated = journal.load();
  QCOMPARE(migrated.kind, LoadKind::Loaded);
  QCOMPARE(migrated.schema, 1);
  QCOMPARE(migrated.record.schema, RecoveryRecord::schemaVersion);
  QVERIFY(QFile::remove(paths.recoveryFile));
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
  record.hardware = HardwareRecord{QStringLiteral("device-id"), QStringLiteral("/tmp/device"),
                                   QStringLiteral("boot"), {}, 10, 100, 100, true, {}};
  QVERIFY(!journal.save(record, &error));
  QVERIFY(QFile::remove(quarantined));
  QVERIFY(journal.save(record, &error));
  const RecoveryLoadResult loaded = journal.load();
  QCOMPARE(loaded.kind, LoadKind::Loaded);
  QVERIFY(loaded.record.hardware.has_value());
  QVERIFY(journal.clear(&error));
  QVERIFY(!journal.exists());
}

void DomainTests::unreadableRecoveryRequiresExplicitDiscard() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  const Paths paths = pathsFor(temporary);
  RecoveryJournal journal(paths);
  QVERIFY(writeTestFile(paths.recoveryFile, "{not-json"));
  QCOMPARE(journal.load().kind, LoadKind::Corrupt);
  QVERIFY(!QFileInfo::exists(paths.recoveryFile + QStringLiteral(".lock")));
  QString error;
  QString quarantined;
  QVERIFY(journal.quarantine(&quarantined, &error));
  QCOMPARE(journal.load().kind, LoadKind::Corrupt);
  QVERIFY(journal.discardUnreadable(&error));
  QCOMPARE(journal.load().kind, LoadKind::NoFile);
  QVERIFY(!QFileInfo::exists(quarantined));

  const QString target = temporary.filePath(QStringLiteral("unsafe-target"));
  QVERIFY(writeTestFile(target, "{}"));
  QVERIFY(QFile::link(target, paths.recoveryFile));
  QCOMPARE(journal.load().kind, LoadKind::IoFailure);
  QVERIFY(!journal.discardUnreadable(&error));
  QVERIFY(QFileInfo::exists(paths.recoveryFile));
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

void DomainTests::solarAcrossTimezonesAndCalendarEdges() {
  const QList<QByteArray> zones = {
      "UTC", "Europe/Berlin", "Atlantic/Canary", "America/Los_Angeles",
      "Asia/Kathmandu", "Pacific/Kiritimati", "Pacific/Pago_Pago"};
  const QList<QDate> dates = {
      QDate(2024, 2, 29), QDate(2026, 3, 29), QDate(2026, 6, 21),
      QDate(2026, 10, 25), QDate(2026, 12, 21)};
  const QList<Coordinate> coordinates = {
      {0.0, 0.0}, {28.1, -16.2}, {52.5, 13.4}, {-33.9, 151.2}, {64.1, -21.9}};
  for (const QByteArray &zoneName : zones) {
    const QTimeZone zone(zoneName);
    QVERIFY2(zone.isValid(), zoneName.constData());
    for (const QDate &date : dates) {
      for (const Coordinate &coordinate : coordinates) {
        const QDateTime noon(date, QTime(12, 0), zone);
        const SolarDay day = solarDay(noon, coordinate, zone);
        if (day.condition == SolarDayCondition::Normal) {
          QVERIFY(day.sunrise.isValid());
          QVERIFY(day.sunset.isValid());
          QVERIFY(day.sunrise < day.sunset);
        }
        const SolarSchedule schedule = solarSchedule(noon, coordinate, zone);
        QVERIFY(schedule.nextEvent.has_value());
        QVERIFY(schedule.nextEvent->time > noon);
        QVERIFY(noon.daysTo(schedule.nextEvent->time) <= 370);
      }
    }
  }

  const QTimeZone utc("UTC");
  for (const double latitude : {-90.0, 90.0}) {
    const QDateTime noon(QDate(2026, 1, 15), QTime(12, 0), utc);
    const SolarSchedule schedule = solarSchedule(
        noon, Coordinate{latitude, 179.9}, utc);
    QVERIFY(schedule.nextEvent.has_value());
    QVERIFY(schedule.nextEvent->time.isValid());
    QVERIFY(noon.daysTo(schedule.nextEvent->time) <= 370);
  }
}

void DomainTests::recoveryDecisionPreservesUserChanges() {
  HardwareRecord record{QStringLiteral("id"), QStringLiteral("/tmp/device"),
                        QStringLiteral("boot"), QStringLiteral("session"), 40, 100, 100, true, {}};
  QCOMPARE(decideHardwareRestore(record, 100, QStringLiteral("boot"), QStringLiteral("session")), HardwareRestoreDecision::Restore);
  QCOMPARE(decideHardwareRestore(record, 40, QStringLiteral("boot"), QStringLiteral("session")), HardwareRestoreDecision::NothingToRestore);
  QCOMPARE(decideHardwareRestore(record, 70, QStringLiteral("boot"), QStringLiteral("session")), HardwareRestoreDecision::PreserveUncertain);
  QCOMPARE(decideHardwareRestore(record, 100, QStringLiteral("new-boot"), QStringLiteral("session")), HardwareRestoreDecision::PreserveUncertain);
  QCOMPARE(decideHardwareRestore(record, 100, QStringLiteral("boot"), QStringLiteral("new-session")), HardwareRestoreDecision::PreserveUncertain);
  QCOMPARE(decideHardwareRestore(record, 100, QString(), QStringLiteral("session")), HardwareRestoreDecision::PreserveUncertain);
  record.sessionIdHash.clear();
  QCOMPARE(decideHardwareRestore(record, 100, QStringLiteral("boot"), QStringLiteral("session")), HardwareRestoreDecision::PreserveUncertain);
  record.sessionIdHash = QStringLiteral("session");

  AutomaticBrightnessRecord automatic{QStringLiteral("id"), QStringLiteral("/tmp/device"),
      QStringLiteral("sysfs:auto_brightness:boolean-v1"), QStringLiteral("boot"),
      QStringLiteral("session"), 1, 0, true, {}};
  QCOMPARE(decideAutomaticBrightnessRestore(automatic, 0, QStringLiteral("boot"), QStringLiteral("session")),
           HardwareRestoreDecision::Restore);
  QCOMPARE(decideAutomaticBrightnessRestore(automatic, 1, QStringLiteral("boot"), QStringLiteral("session")),
           HardwareRestoreDecision::NothingToRestore);
}

void DomainTests::backlightCapabilityIsUnambiguous() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  QVERIFY(createFakeBacklightTree(temporary));
  qputenv("EMBER_BACKLIGHT_ROOT", temporary.filePath(QStringLiteral("backlight")).toUtf8());
  qputenv("EMBER_DRM_ROOT", temporary.filePath(QStringLiteral("drm")).toUtf8());
  qputenv("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER", "sysfs-boolean-v1");
  qputenv("XDG_SESSION_ID", "ember-domain-test-session");
  const auto environment = qScopeGuard([] {
    qunsetenv("EMBER_BACKLIGHT_ROOT");
    qunsetenv("EMBER_DRM_ROOT");
    qunsetenv("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER");
    qunsetenv("XDG_SESSION_ID");
  });
  const Paths paths = pathsFor(temporary);
  BacklightController controller(paths);
  const BacklightCapability capability = controller.probe();
  QVERIFY2(capability.available, qPrintable(capability.reason));
  QCOMPARE(capability.maximum, 100);
  QCOMPARE(capability.brightness, 40);
  QVERIFY(capability.automaticBrightnessAvailable);
  QCOMPARE(capability.automaticBrightness, 1);

  qunsetenv("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER");
  const BacklightCapability productionSemantics = controller.probe();
  QVERIFY(productionSemantics.available);
  QVERIFY(!productionSemantics.automaticBrightnessAvailable);
  QVERIFY(productionSemantics.automaticBrightnessReason.contains(QStringLiteral("unmanaged")));
  qputenv("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER", "sysfs-boolean-v1");

  QVERIFY(createFakeBacklightTree(temporary, true, QStringLiteral("acpi_video0")));
  const BacklightCapability ambiguous = controller.probe();
  QVERIFY(!ambiguous.available);
  QVERIFY(ambiguous.reason.contains(QStringLiteral("Multiple")));
}

void DomainTests::backlightRestoresFieldsIndependently() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  QVERIFY(createFakeBacklightTree(temporary));
  qputenv("EMBER_BACKLIGHT_ROOT", temporary.filePath(QStringLiteral("backlight")).toUtf8());
  qputenv("EMBER_DRM_ROOT", temporary.filePath(QStringLiteral("drm")).toUtf8());
  qputenv("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER", "sysfs-boolean-v1");
  qputenv("XDG_SESSION_ID", "ember-domain-restore-session");
  const auto environment = qScopeGuard([] {
    qunsetenv("EMBER_BACKLIGHT_ROOT");
    qunsetenv("EMBER_DRM_ROOT");
    qunsetenv("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER");
    qunsetenv("XDG_SESSION_ID");
  });
  BacklightController controller(pathsFor(temporary));
  const BacklightCapability capability = controller.probe();
  QVERIFY2(capability.available, qPrintable(capability.reason));
  QVERIFY(controller.write(capability, 100));
  QVERIFY(controller.writeAutomaticBrightness(capability, 0));

  RecoveryRecord record;
  HardwareRecord hardware;
  hardware.deviceId = capability.deviceId;
  hardware.devicePath = capability.devicePath;
  hardware.bootIdHash = hashBootId();
  hardware.sessionIdHash = hashSessionId();
  hardware.originalBrightness = 40;
  hardware.lastWrittenBrightness = 100;
  hardware.maximumBrightness = 100;
  record.hardware = hardware;
  AutomaticBrightnessRecord automatic;
  automatic.deviceId = capability.deviceId;
  automatic.devicePath = capability.devicePath;
  automatic.provider = capability.automaticBrightnessProvider;
  automatic.bootIdHash = hashBootId();
  automatic.sessionIdHash = hashSessionId();
  automatic.originalValue = 1;
  automatic.lastWrittenValue = 0;
  record.automaticBrightness = automatic;
  QString error;
  QVERIFY2(controller.restore(&record, &error), qPrintable(error));
  QVERIFY(!recoveryRecordHasPendingFields(record));
  int current = -1;
  QVERIFY(controller.read(capability, &current));
  QCOMPARE(current, 40);
  QVERIFY(controller.readAutomaticBrightness(capability, &current));
  QCOMPARE(current, 1);

  QVERIFY(controller.write(capability, 70));
  QVERIFY(controller.writeAutomaticBrightness(capability, 0));
  record.hardware = hardware;
  record.automaticBrightness = automatic;
  QVERIFY(!controller.restore(&record, &error));
  QVERIFY(record.hardware.has_value());
  QVERIFY(!record.automaticBrightness.has_value());
  QVERIFY(controller.read(capability, &current));
  QCOMPARE(current, 70);
  QVERIFY(controller.readAutomaticBrightness(capability, &current));
  QCOMPARE(current, 1);
}

void DomainTests::guardianRequiresCurrentSupervisedInvocation() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  const Paths paths = pathsFor(temporary);
  BacklightController controller(paths);
  qunsetenv("INVOCATION_ID");
  QString error;
  QVERIFY(!controller.armGuardian(&error));
  qputenv("INVOCATION_ID", "supervised-invocation-a");
  QVERIFY2(controller.armGuardian(&error), qPrintable(error));
  QVERIFY(controller.guardianArmed());
  qputenv("INVOCATION_ID", "supervised-invocation-b");
  QVERIFY(!controller.guardianArmed());
  QVERIFY(controller.disarmGuardian());
  qunsetenv("INVOCATION_ID");
}

void DomainTests::diagnosticsAreSanitized() {
  QVariantMap source;
  source.insert(QStringLiteral("location"), QStringLiteral("28.1,-16.2"));
  source.insert(QStringLiteral("home"), QStringLiteral("/home/user"));
  source.insert(QStringLiteral("rawSerials"), QStringLiteral("secret"));
  source.insert(QStringLiteral("attentionMessage"), QDir::homePath() + QStringLiteral("/private-state"));
  source.insert(QStringLiteral("requestProcessed"), true);
  const QVariantMap sanitized = sanitizedDiagnostics(source);
  QVERIFY(!sanitized.contains(QStringLiteral("location")));
  QVERIFY(!sanitized.contains(QStringLiteral("home")));
  QVERIFY(!sanitized.contains(QStringLiteral("rawSerials")));
  if (QDir::homePath() != QStringLiteral("/")) {
    QVERIFY(!sanitized.value(QStringLiteral("attentionMessage")).toString().contains(QDir::homePath()));
  }
  QCOMPARE(sanitized.value(QStringLiteral("pixelsVerified")).toBool(), false);
}

QTEST_APPLESS_MAIN(DomainTests)

#include "DomainTests.moc"
