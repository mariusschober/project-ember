#pragma once

#include "core/Model.h"

#include <QString>

namespace ember {

enum class HardwareRestoreDecision { Restore, PreserveUncertain, NothingToRestore };

HardwareRestoreDecision decideHardwareRestore(const HardwareRecord &record, int currentBrightness, const QString &currentBootIdHash);
bool hardwareRecordIsComplete(const HardwareRecord &record);

} // namespace ember
