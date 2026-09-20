#include "core/Recovery.h"

namespace ember {

bool hardwareRecordIsComplete(const HardwareRecord &record) {
  return !record.deviceId.isEmpty() && !record.devicePath.isEmpty()
      && record.originalBrightness >= 0 && record.lastWrittenBrightness >= 0
      && record.maximumBrightness > 0;
}

HardwareRestoreDecision decideHardwareRestore(const HardwareRecord &record, int currentBrightness, const QString &currentBootIdHash) {
  if (!hardwareRecordIsComplete(record) || currentBrightness < 0) return HardwareRestoreDecision::PreserveUncertain;
  if (!currentBootIdHash.isEmpty() && !record.bootIdHash.isEmpty() && record.bootIdHash != currentBootIdHash) {
    // A boot-id mismatch means the value may have been changed by firmware,
    // a desktop service, or the user. Do not replay an old journal blindly.
    return HardwareRestoreDecision::PreserveUncertain;
  }
  if (currentBrightness == record.originalBrightness) return HardwareRestoreDecision::NothingToRestore;
  if (currentBrightness != record.lastWrittenBrightness) return HardwareRestoreDecision::PreserveUncertain;
  return HardwareRestoreDecision::Restore;
}

} // namespace ember
