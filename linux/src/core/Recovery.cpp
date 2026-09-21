#include "core/Recovery.h"

namespace ember {

bool hardwareRecordIsComplete(const HardwareRecord &record) {
  return !record.deviceId.isEmpty() && !record.devicePath.isEmpty()
      && record.originalBrightness >= 0 && record.lastWrittenBrightness >= 0
      && record.maximumBrightness > 0
      && record.originalBrightness <= record.maximumBrightness
      && record.lastWrittenBrightness <= record.maximumBrightness;
}

namespace {

HardwareRestoreDecision decideRestore(int originalValue, int lastWrittenValue, int currentValue,
                                      const QString &recordBootIdHash, const QString &currentBootIdHash,
                                      const QString &recordSessionIdHash, const QString &currentSessionIdHash) {
  if (originalValue < 0 || lastWrittenValue < 0 || currentValue < 0) return HardwareRestoreDecision::PreserveUncertain;
  if (currentBootIdHash.isEmpty() || recordBootIdHash.isEmpty() || recordBootIdHash != currentBootIdHash) {
    return HardwareRestoreDecision::PreserveUncertain;
  }
  if (currentSessionIdHash.isEmpty() || recordSessionIdHash.isEmpty() || recordSessionIdHash != currentSessionIdHash) {
    return HardwareRestoreDecision::PreserveUncertain;
  }
  if (currentValue == originalValue) return HardwareRestoreDecision::NothingToRestore;
  if (currentValue != lastWrittenValue) return HardwareRestoreDecision::PreserveUncertain;
  return HardwareRestoreDecision::Restore;
}

} // namespace

HardwareRestoreDecision decideHardwareRestore(const HardwareRecord &record, int currentBrightness,
                                              const QString &currentBootIdHash,
                                              const QString &currentSessionIdHash) {
  if (!hardwareRecordIsComplete(record) || currentBrightness < 0) return HardwareRestoreDecision::PreserveUncertain;
  return decideRestore(record.originalBrightness, record.lastWrittenBrightness, currentBrightness,
                       record.bootIdHash, currentBootIdHash, record.sessionIdHash, currentSessionIdHash);
}

bool automaticBrightnessRecordIsComplete(const AutomaticBrightnessRecord &record) {
  return !record.deviceId.isEmpty() && !record.devicePath.isEmpty() && !record.provider.isEmpty()
      && (record.originalValue == 0 || record.originalValue == 1)
      && (record.lastWrittenValue == 0 || record.lastWrittenValue == 1);
}

HardwareRestoreDecision decideAutomaticBrightnessRestore(const AutomaticBrightnessRecord &record, int currentValue,
                                                         const QString &currentBootIdHash,
                                                         const QString &currentSessionIdHash) {
  if (!automaticBrightnessRecordIsComplete(record) || (currentValue != 0 && currentValue != 1)) {
    return HardwareRestoreDecision::PreserveUncertain;
  }
  return decideRestore(record.originalValue, record.lastWrittenValue, currentValue,
                       record.bootIdHash, currentBootIdHash, record.sessionIdHash, currentSessionIdHash);
}

bool recoveryRecordHasPendingFields(const RecoveryRecord &record) {
  return record.hardware.has_value() || record.automaticBrightness.has_value();
}

} // namespace ember
