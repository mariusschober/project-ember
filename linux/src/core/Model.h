#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <QString>

namespace ember {

struct ColorGains {
  float red = 1.0F;
  float green = 1.0F;
  float blue = 1.0F;

  friend bool operator==(const ColorGains &, const ColorGains &) = default;
};

struct ColorMatrix {
  std::array<double, 9> values{};

  friend bool operator==(const ColorMatrix &, const ColorMatrix &) = default;
};

enum class Preset { Neutral, Evening, PureRed };

enum class PrimaryAction { OpenControls, ToggleEmber };

struct Coordinate {
  double latitude = 0.0;
  double longitude = 0.0;

  friend bool operator==(const Coordinate &, const Coordinate &) = default;
};

struct Settings {
  static constexpr int schemaVersion = 1;

  double warmth = 0.62;
  double brightness = 0.75;
  bool filterEnabled = false;
  bool backlightLockEnabled = false;
  bool launchAtLogin = false;
  bool sunScheduleEnabled = false;
  bool automationPaused = false;
  PrimaryAction primaryAction = PrimaryAction::OpenControls;
  std::optional<Coordinate> location;
  std::optional<std::int64_t> overrideExpiresAtMs;
  bool overrideFilterEnabled = false;

  friend bool operator==(const Settings &, const Settings &) = default;

  static Settings defaults();
  bool validate(QString *reason = nullptr) const;
  void normalize();
};

enum class RuntimeState {
  Off,
  Enabling,
  CompositorControlled,
  Reconciling,
  Restoring,
  Suspended,
  Blocked,
  Unsupported,
  Degraded,
};

QString runtimeStateName(RuntimeState state);
QString primaryActionName(PrimaryAction action);
std::optional<PrimaryAction> primaryActionFromName(const QString &name);
std::optional<Preset> presetFromName(const QString &name);
QString presetName(Preset preset);

ColorGains gainsForWarmth(double warmth);
std::optional<double> approximateKelvin(double warmth);
ColorGains gainsForKelvin(double kelvin);
ColorMatrix matrixFor(const Settings &settings);
double presetWarmth(Preset preset);

bool finiteNonNegativeMatrix(const ColorMatrix &matrix);
std::int32_t fixed24_8(double value);
double fixed24_8ToDouble(std::int32_t value);

struct HardwareRecord {
  QString deviceId;
  QString devicePath;
  QString bootIdHash;
  int originalBrightness = -1;
  int lastWrittenBrightness = -1;
  int maximumBrightness = 0;
  bool unresolved = false;
  QString error;
};

struct RecoveryRecord {
  static constexpr int schemaVersion = 1;

  int schema = schemaVersion;
  QString appVersion = QStringLiteral("0.1.0-linux-alpha.1");
  std::int64_t createdAtMs = 0;
  std::optional<HardwareRecord> hardware;
  bool safetyPaused = false;
};

QString describeWarmth(double warmth);

} // namespace ember
