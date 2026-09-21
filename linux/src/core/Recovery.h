#pragma once

#include "core/Model.h"

#include <QString>

namespace ember {

enum class HardwareRestoreDecision { Restore, PreserveUncertain, NothingToRestore };

HardwareRestoreDecision decideHardwareRestore(const HardwareRecord &record, int currentBrightness,
                                              const QString &currentBootIdHash,
                                              const QString &currentSessionIdHash = {});
HardwareRestoreDecision decideAutomaticBrightnessRestore(const AutomaticBrightnessRecord &record, int currentValue,
                                                         const QString &currentBootIdHash,
                                                         const QString &currentSessionIdHash = {});
bool hardwareRecordIsComplete(const HardwareRecord &record);
bool automaticBrightnessRecordIsComplete(const AutomaticBrightnessRecord &record);
bool recoveryRecordHasPendingFields(const RecoveryRecord &record);

} // namespace ember
