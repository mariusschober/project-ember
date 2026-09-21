#include "core/Persistence.h"
#include "platform/Backlight.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QLockFile>
#include <QTextStream>

#include <csignal>
#include <unistd.h>

using namespace ember;

int main(int argc, char **argv) {
  QCoreApplication application(argc, argv);
  const Paths paths = Paths::fromEnvironment();
  QString error;
  if (!ensurePrivateDirectory(paths.runtimeDir, &error)) return 1;
  QLockFile controllerLock(paths.controllerLockFile);
  controllerLock.setStaleLockTime(5000);
  if (!controllerLock.tryLock(0)) return 1;
  BacklightController backlight(paths);
  const BacklightCapability capability = backlight.probe();
  if (!capability.available) {
    QTextStream(stderr) << capability.reason << '\n';
    return 1;
  }
  const QString bootId = hashBootId();
  const QString sessionId = hashSessionId();
  if (bootId.isEmpty() || sessionId.isEmpty()) return 1;

  int originalBrightness = -1;
  if (!backlight.read(capability, &originalBrightness, &error)) return 1;

  RecoveryRecord record;
  record.createdAtMs = QDateTime::currentMSecsSinceEpoch();
  HardwareRecord hardware;
  hardware.deviceId = capability.deviceId;
  hardware.devicePath = capability.devicePath;
  hardware.bootIdHash = bootId;
  hardware.sessionIdHash = sessionId;
  hardware.originalBrightness = originalBrightness;
  hardware.lastWrittenBrightness = capability.maximum;
  hardware.maximumBrightness = capability.maximum;
  hardware.unresolved = true;
  record.hardware = hardware;

  if (capability.automaticBrightnessAvailable) {
    int originalAutomatic = -1;
    if (!backlight.readAutomaticBrightness(capability, &originalAutomatic, &error)) return 1;
    if (originalAutomatic == 1) {
      AutomaticBrightnessRecord automatic;
      automatic.deviceId = capability.deviceId;
      automatic.devicePath = capability.devicePath;
      automatic.provider = capability.automaticBrightnessProvider;
      automatic.bootIdHash = bootId;
      automatic.sessionIdHash = sessionId;
      automatic.originalValue = 1;
      automatic.lastWrittenValue = 0;
      automatic.unresolved = true;
      record.automaticBrightness = automatic;
    }
  }

  RecoveryJournal journal(paths);
  if (!journal.save(record, &error)) return 1;
  if (record.automaticBrightness.has_value()
      && !backlight.writeAutomaticBrightness(capability, 0, &error)) return 1;
  if (!backlight.write(capability, capability.maximum, &error)) return 1;
  record.hardware->unresolved = false;
  if (record.automaticBrightness.has_value()) record.automaticBrightness->unresolved = false;
  if (!journal.save(record, &error)) return 1;

  QTextStream output(stdout);
  output << "READY\n";
  output.flush();
  for (;;) pause();
}
