#include "core/Persistence.h"
#include "core/Recovery.h"
#include "platform/Backlight.h"

#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QProcessEnvironment>
#include <QScopeGuard>
#include <QTemporaryDir>
#include <QtTest>

using namespace ember;

namespace {

Paths pathsFor(const QTemporaryDir &temporary) {
  Paths paths;
  paths.configDir = temporary.filePath(QStringLiteral("config/project-ember"));
  paths.stateDir = temporary.filePath(QStringLiteral("state/project-ember"));
  paths.runtimeDir = temporary.filePath(QStringLiteral("runtime/project-ember"));
  paths.settingsFile = QDir(paths.configDir).filePath(QStringLiteral("settings.json"));
  paths.recoveryFile = QDir(paths.stateDir).filePath(QStringLiteral("recovery.json"));
  paths.safetyLatchFile = QDir(paths.stateDir).filePath(QStringLiteral("automation-paused"));
  paths.guardianFile = QDir(paths.runtimeDir).filePath(QStringLiteral("guardian.json"));
  paths.cleanExitFile = QDir(paths.runtimeDir).filePath(QStringLiteral("clean-exit"));
  return paths;
}

bool writeFile(const QString &path, const QByteArray &value) {
  if (!QDir().mkpath(QFileInfo(path).absolutePath())) return false;
  QFile file(path);
  if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
  if (file.write(value) != value.size()) return false;
  file.close();
  return QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
}

bool createHardware(const QTemporaryDir &temporary) {
  const QString backlight = temporary.filePath(QStringLiteral("backlight/intel_backlight"));
  const QString connector = temporary.filePath(QStringLiteral("drm/card0-eDP-1"));
  const QString gpu = temporary.filePath(QStringLiteral("devices/gpu0"));
  const QString driver = temporary.filePath(QStringLiteral("drivers/intel"));
  if (!QDir().mkpath(backlight) || !QDir().mkpath(connector)
      || !QDir().mkpath(gpu) || !QDir().mkpath(driver)) return false;
  const QString brightness = QDir(backlight).filePath(QStringLiteral("brightness"));
  const bool created = QFile::link(gpu, QDir(backlight).filePath(QStringLiteral("device")))
      && QFile::link(driver, QDir(gpu).filePath(QStringLiteral("driver")))
      && QFile::link(gpu, QDir(connector).filePath(QStringLiteral("device")))
      && writeFile(QDir(backlight).filePath(QStringLiteral("max_brightness")), "100")
      && writeFile(brightness, "40")
      && writeFile(QDir(backlight).filePath(QStringLiteral("auto_brightness")), "1")
      && writeFile(QDir(backlight).filePath(QStringLiteral("type")), "raw")
      && writeFile(QDir(connector).filePath(QStringLiteral("status")), "connected\n")
      && writeFile(QDir(connector).filePath(QStringLiteral("edid")), QByteArray::fromHex("00ffffffffffff004c2d010203040506"));
  return created && QFile::link(brightness, QDir(backlight).filePath(QStringLiteral("actual_brightness")));
}

QProcessEnvironment environmentFor(const QTemporaryDir &temporary) {
  QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
  environment.insert(QStringLiteral("XDG_CONFIG_HOME"), temporary.filePath(QStringLiteral("config")));
  environment.insert(QStringLiteral("XDG_STATE_HOME"), temporary.filePath(QStringLiteral("state")));
  environment.insert(QStringLiteral("XDG_RUNTIME_DIR"), temporary.filePath(QStringLiteral("runtime")));
  environment.insert(QStringLiteral("EMBER_BACKLIGHT_ROOT"), temporary.filePath(QStringLiteral("backlight")));
  environment.insert(QStringLiteral("EMBER_DRM_ROOT"), temporary.filePath(QStringLiteral("drm")));
  environment.insert(QStringLiteral("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER"), QStringLiteral("sysfs-boolean-v1"));
  environment.insert(QStringLiteral("EMBER_TEST_ALLOW_ROOT"), QStringLiteral("1"));
  environment.insert(QStringLiteral("INVOCATION_ID"), QStringLiteral("process-recovery-test"));
  environment.insert(QStringLiteral("XDG_SESSION_ID"), QStringLiteral("ember-test-session"));
  environment.remove(QStringLiteral("WAYLAND_DISPLAY"));
  return environment;
}

struct ProcessResult {
  bool started = false;
  bool finished = false;
  int exitCode = -1;
  QByteArray output;
};

ProcessResult runProjectEmber(const QProcessEnvironment &environment, const QStringList &arguments) {
  QProcess process;
  process.setProcessEnvironment(environment);
  process.setProcessChannelMode(QProcess::MergedChannels);
  process.start(QStringLiteral(EMBER_PROJECT_BINARY), arguments);
  ProcessResult result;
  result.started = process.waitForStarted(2000);
  result.finished = result.started && process.waitForFinished(5000);
  if (!result.finished) {
    process.kill();
    (void)process.waitForFinished(1000);
  }
  result.exitCode = process.exitCode();
  result.output = process.readAll();
  return result;
}

RecoveryRecord engagedRecord(const BacklightCapability &capability) {
  RecoveryRecord record;
  record.createdAtMs = 1;
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
  return record;
}

} // namespace

class ProcessRecoveryTests final : public QObject {
  Q_OBJECT

private slots:
  void abnormalCleanupRestoresAndPauses();
  void killedEngagedProcessIsRecovered();
  void cleanCleanupPreservesIntentionalPreferences();
  void emergencyRestoreClearsBacklightPreference();
  void uncertainBrightnessPreservesOnlyUnresolvedField();
  void readOnlyCommandsDoNotCreateStateOrStartService();
};

void ProcessRecoveryTests::killedEngagedProcessIsRecovered() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  QVERIFY(createHardware(temporary));
  const QProcessEnvironment environment = environmentFor(temporary);
  const Paths paths = pathsFor(temporary);
  Settings settings = Settings::defaults();
  settings.filterEnabled = true;
  settings.backlightLockEnabled = true;
  settings.sunScheduleEnabled = true;
  QString error;
  QVERIFY(SettingsStore(paths).save(settings, &error));

  ProcessResult arm = runProjectEmber(environment, {QStringLiteral("--arm-guardian")});
  QVERIFY2(arm.started && arm.finished && arm.exitCode == 0, arm.output.constData());

  QProcess fixture;
  fixture.setProcessEnvironment(environment);
  fixture.setProcessChannelMode(QProcess::MergedChannels);
  fixture.start(QStringLiteral(EMBER_RECOVERY_FIXTURE));
  QVERIFY(fixture.waitForStarted(2000));
  QByteArray fixtureOutput;
  QElapsedTimer readyTimer;
  readyTimer.start();
  while (!fixtureOutput.contains("READY\n") && readyTimer.elapsed() < 3000) {
    (void)fixture.waitForReadyRead(100);
    fixtureOutput += fixture.readAll();
  }
  QVERIFY2(fixtureOutput.contains("READY\n"), fixtureOutput.constData());

  qputenv("EMBER_BACKLIGHT_ROOT", environment.value(QStringLiteral("EMBER_BACKLIGHT_ROOT")).toUtf8());
  qputenv("EMBER_DRM_ROOT", environment.value(QStringLiteral("EMBER_DRM_ROOT")).toUtf8());
  qputenv("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER", "sysfs-boolean-v1");
  const auto resetEnvironment = qScopeGuard([] {
    qunsetenv("EMBER_BACKLIGHT_ROOT"); qunsetenv("EMBER_DRM_ROOT");
    qunsetenv("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER");
  });
  BacklightController backlight(paths);
  const BacklightCapability capability = backlight.probe();
  QVERIFY2(capability.available, qPrintable(capability.reason));
  int observed = -1;
  QVERIFY(backlight.read(capability, &observed));
  QCOMPARE(observed, 100);
  QVERIFY(backlight.readAutomaticBrightness(capability, &observed));
  QCOMPARE(observed, 0);

  fixture.kill();
  QVERIFY(fixture.waitForFinished(2000));
  QCOMPARE(fixture.exitStatus(), QProcess::CrashExit);
  ProcessResult recovered = runProjectEmber(environment, {QStringLiteral("--recover-hardware")});
  QVERIFY2(recovered.started && recovered.finished && recovered.exitCode == 0, recovered.output.constData());
  QVERIFY(backlight.read(capability, &observed));
  QCOMPARE(observed, 40);
  QVERIFY(backlight.readAutomaticBrightness(capability, &observed));
  QCOMPARE(observed, 1);
  QCOMPARE(RecoveryJournal(paths).load().kind, LoadKind::NoFile);
  const SettingsLoadResult loaded = SettingsStore(paths).load();
  QCOMPARE(loaded.kind, LoadKind::Loaded);
  QVERIFY(!loaded.settings.filterEnabled);
  QVERIFY(loaded.settings.automationPaused);
  QVERIFY(QFileInfo::exists(paths.safetyLatchFile));
}

void ProcessRecoveryTests::readOnlyCommandsDoNotCreateStateOrStartService() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  QProcessEnvironment environment = environmentFor(temporary);
  environment.insert(QStringLiteral("EMBER_SYSTEMCTL"), QStringLiteral("/bin/false"));
  for (const QString &command : {QStringLiteral("status"), QStringLiteral("doctor"),
                                 QStringLiteral("--system-probe")}) {
    const ProcessResult result = runProjectEmber(environment, {command, QStringLiteral("--json")});
    QVERIFY2(result.started && result.finished && result.exitCode == 0, result.output.constData());
    QVERIFY(result.output.contains("\"pixelsVerified\": false"));
    QVERIFY(!QFileInfo::exists(temporary.filePath(QStringLiteral("config"))));
    QVERIFY(!QFileInfo::exists(temporary.filePath(QStringLiteral("state"))));
    QVERIFY(!QFileInfo::exists(temporary.filePath(QStringLiteral("runtime"))));
  }
  const ProcessResult settings = runProjectEmber(environment, {QStringLiteral("settings")});
  QVERIFY(settings.started && settings.finished);
  QCOMPARE(settings.exitCode, 2);
  QVERIFY(settings.output.contains("managed user service"));
  QVERIFY(!QFileInfo::exists(temporary.filePath(QStringLiteral("config"))));
  QVERIFY(!QFileInfo::exists(temporary.filePath(QStringLiteral("state"))));
  QVERIFY(!QFileInfo::exists(temporary.filePath(QStringLiteral("runtime"))));
}

void ProcessRecoveryTests::abnormalCleanupRestoresAndPauses() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  QVERIFY(createHardware(temporary));
  const QProcessEnvironment environment = environmentFor(temporary);
  qputenv("EMBER_BACKLIGHT_ROOT", environment.value(QStringLiteral("EMBER_BACKLIGHT_ROOT")).toUtf8());
  qputenv("EMBER_DRM_ROOT", environment.value(QStringLiteral("EMBER_DRM_ROOT")).toUtf8());
  qputenv("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER", "sysfs-boolean-v1");
  qputenv("XDG_SESSION_ID", "ember-test-session");
  qputenv("INVOCATION_ID", "process-recovery-test");
  const auto resetEnvironment = qScopeGuard([] {
    qunsetenv("EMBER_BACKLIGHT_ROOT"); qunsetenv("EMBER_DRM_ROOT");
    qunsetenv("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER");
    qunsetenv("XDG_SESSION_ID"); qunsetenv("INVOCATION_ID");
  });
  const Paths paths = pathsFor(temporary);
  BacklightController backlight(paths);
  const BacklightCapability capability = backlight.probe();
  QVERIFY2(capability.available, qPrintable(capability.reason));
  QVERIFY(backlight.write(capability, 100));
  QVERIFY(backlight.writeAutomaticBrightness(capability, 0));
  RecoveryJournal journal(paths);
  QString error;
  QVERIFY(journal.save(engagedRecord(capability), &error));
  Settings settings = Settings::defaults();
  settings.filterEnabled = true;
  settings.backlightLockEnabled = true;
  settings.sunScheduleEnabled = true;
  QVERIFY(SettingsStore(paths).save(settings, &error));

  ProcessResult result = runProjectEmber(environment, {QStringLiteral("--arm-guardian")});
  QVERIFY2(result.started && result.finished && result.exitCode == 0, result.output.constData());
  result = runProjectEmber(environment, {QStringLiteral("--recover-hardware")});
  QVERIFY2(result.started && result.finished && result.exitCode == 0, result.output.constData());
  int observed = -1;
  QVERIFY(backlight.read(capability, &observed));
  QCOMPARE(observed, 40);
  QVERIFY(backlight.readAutomaticBrightness(capability, &observed));
  QCOMPARE(observed, 1);
  QCOMPARE(journal.load().kind, LoadKind::NoFile);
  const SettingsLoadResult loaded = SettingsStore(paths).load();
  QCOMPARE(loaded.kind, LoadKind::Loaded);
  QVERIFY(!loaded.settings.filterEnabled);
  QVERIFY(loaded.settings.backlightLockEnabled);
  QVERIFY(loaded.settings.automationPaused);
  QVERIFY(QFileInfo::exists(paths.safetyLatchFile));
  QVERIFY(!QFileInfo::exists(paths.guardianFile));
}

void ProcessRecoveryTests::cleanCleanupPreservesIntentionalPreferences() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  QVERIFY(createHardware(temporary));
  const Paths paths = pathsFor(temporary);
  Settings settings = Settings::defaults();
  settings.filterEnabled = true;
  settings.backlightLockEnabled = true;
  QString error;
  QVERIFY(SettingsStore(paths).save(settings, &error));
  QVERIFY(writeDurableFile(paths.cleanExitFile, "clean\n", 0600, &error));
  const QProcessEnvironment environment = environmentFor(temporary);
  ProcessResult result = runProjectEmber(environment, {QStringLiteral("--arm-guardian")});
  QVERIFY2(result.started && result.finished && result.exitCode == 0, result.output.constData());
  result = runProjectEmber(environment, {QStringLiteral("--recover-hardware")});
  QVERIFY2(result.started && result.finished && result.exitCode == 0, result.output.constData());
  const SettingsLoadResult loaded = SettingsStore(paths).load();
  QCOMPARE(loaded.kind, LoadKind::Loaded);
  QVERIFY(loaded.settings.filterEnabled);
  QVERIFY(loaded.settings.backlightLockEnabled);
  QVERIFY(!loaded.settings.automationPaused);
  QVERIFY(!QFileInfo::exists(paths.cleanExitFile));
  QVERIFY(!QFileInfo::exists(paths.guardianFile));
}

void ProcessRecoveryTests::emergencyRestoreClearsBacklightPreference() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  QVERIFY(createHardware(temporary));
  const Paths paths = pathsFor(temporary);
  Settings settings = Settings::defaults();
  settings.filterEnabled = true;
  settings.backlightLockEnabled = true;
  settings.sunScheduleEnabled = true;
  QString error;
  QVERIFY(SettingsStore(paths).save(settings, &error));
  const ProcessResult result = runProjectEmber(environmentFor(temporary), {QStringLiteral("restore")});
  QVERIFY2(result.started && result.finished && result.exitCode == 0, result.output.constData());
  const SettingsLoadResult loaded = SettingsStore(paths).load();
  QCOMPARE(loaded.kind, LoadKind::Loaded);
  QVERIFY(!loaded.settings.filterEnabled);
  QVERIFY(!loaded.settings.backlightLockEnabled);
  QVERIFY(loaded.settings.automationPaused);
}

void ProcessRecoveryTests::uncertainBrightnessPreservesOnlyUnresolvedField() {
  QTemporaryDir temporary;
  QVERIFY(temporary.isValid());
  QVERIFY(createHardware(temporary));
  const QProcessEnvironment environment = environmentFor(temporary);
  qputenv("EMBER_BACKLIGHT_ROOT", environment.value(QStringLiteral("EMBER_BACKLIGHT_ROOT")).toUtf8());
  qputenv("EMBER_DRM_ROOT", environment.value(QStringLiteral("EMBER_DRM_ROOT")).toUtf8());
  qputenv("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER", "sysfs-boolean-v1");
  qputenv("XDG_SESSION_ID", "ember-test-session");
  const auto resetEnvironment = qScopeGuard([] {
    qunsetenv("EMBER_BACKLIGHT_ROOT"); qunsetenv("EMBER_DRM_ROOT");
    qunsetenv("EMBER_TEST_AUTOMATIC_BRIGHTNESS_PROVIDER"); qunsetenv("XDG_SESSION_ID");
  });
  const Paths paths = pathsFor(temporary);
  BacklightController backlight(paths);
  const BacklightCapability capability = backlight.probe();
  QVERIFY(capability.available);
  QVERIFY(backlight.write(capability, 70));
  QVERIFY(backlight.writeAutomaticBrightness(capability, 0));
  QString error;
  QVERIFY(RecoveryJournal(paths).save(engagedRecord(capability), &error));
  const ProcessResult result = runProjectEmber(environment, {QStringLiteral("--recover-hardware")});
  QVERIFY(result.started && result.finished);
  QCOMPARE(result.exitCode, 1);
  int observed = -1;
  QVERIFY(backlight.read(capability, &observed));
  QCOMPARE(observed, 70);
  QVERIFY(backlight.readAutomaticBrightness(capability, &observed));
  QCOMPARE(observed, 1);
  const RecoveryLoadResult loaded = RecoveryJournal(paths).load();
  QCOMPARE(loaded.kind, LoadKind::Loaded);
  QVERIFY(loaded.record.hardware.has_value());
  QVERIFY(!loaded.record.automaticBrightness.has_value());
  QVERIFY(!QFileInfo::exists(paths.guardianFile));
}

QTEST_APPLESS_MAIN(ProcessRecoveryTests)

#include "ProcessRecoveryTests.moc"
