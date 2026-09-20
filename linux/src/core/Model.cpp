#include "core/Model.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace ember {

namespace {

double clamp(double value, double lower, double upper) {
  return std::min(std::max(value, lower), upper);
}

double smoothstep(double value) {
  const double t = clamp(value, 0.0, 1.0);
  return t * t * (3.0 - (2.0 * t));
}

float clampChannel(double value) {
  return static_cast<float>(clamp(std::max(value, 0.0), 0.0, 1.0));
}

} // namespace

Settings Settings::defaults() { return {}; }

bool Settings::validate(QString *reason) const {
  const auto fail = [reason](const QString &message) {
    if (reason != nullptr) {
      *reason = message;
    }
    return false;
  };
  if (!std::isfinite(warmth) || warmth < 0.0 || warmth > 1.0) {
    return fail(QStringLiteral("warmth must be finite and between 0 and 1"));
  }
  if (!std::isfinite(brightness) || brightness < 0.10 || brightness > 1.0) {
    return fail(QStringLiteral("brightness must be finite and between 0.10 and 1"));
  }
  if (location.has_value()) {
    if (!std::isfinite(location->latitude) || location->latitude < -90.0 || location->latitude > 90.0) {
      return fail(QStringLiteral("latitude must be finite and between -90 and 90"));
    }
    if (!std::isfinite(location->longitude) || location->longitude < -180.0 || location->longitude > 180.0) {
      return fail(QStringLiteral("longitude must be finite and between -180 and 180"));
    }
  }
  if (overrideExpiresAtMs.has_value() && overrideExpiresAtMs.value() < 0) {
    return fail(QStringLiteral("override expiry cannot be negative"));
  }
  return true;
}

void Settings::normalize() {
  if (std::isfinite(warmth)) {
    warmth = clamp(warmth, 0.0, 1.0);
  }
  if (std::isfinite(brightness)) {
    brightness = clamp(brightness, 0.10, 1.0);
  }
  if (location.has_value()) {
    location->latitude = clamp(location->latitude, -90.0, 90.0);
    location->longitude = clamp(location->longitude, -180.0, 180.0);
    location->latitude = std::round(location->latitude * 10.0) / 10.0;
    location->longitude = std::round(location->longitude * 10.0) / 10.0;
  }
}

QString runtimeStateName(RuntimeState state) {
  switch (state) {
  case RuntimeState::Off: return QStringLiteral("off");
  case RuntimeState::Enabling: return QStringLiteral("enabling");
  case RuntimeState::CompositorControlled: return QStringLiteral("compositor_controlled");
  case RuntimeState::Reconciling: return QStringLiteral("reconciling");
  case RuntimeState::Restoring: return QStringLiteral("restoring");
  case RuntimeState::Suspended: return QStringLiteral("suspended");
  case RuntimeState::Blocked: return QStringLiteral("blocked");
  case RuntimeState::Unsupported: return QStringLiteral("unsupported");
  case RuntimeState::Degraded: return QStringLiteral("degraded");
  }
  return QStringLiteral("unknown");
}

QString primaryActionName(PrimaryAction action) {
  return action == PrimaryAction::ToggleEmber ? QStringLiteral("toggleEmber") : QStringLiteral("openControls");
}

std::optional<PrimaryAction> primaryActionFromName(const QString &name) {
  if (name == QStringLiteral("openControls")) return PrimaryAction::OpenControls;
  if (name == QStringLiteral("toggleEmber")) return PrimaryAction::ToggleEmber;
  return std::nullopt;
}

std::optional<Preset> presetFromName(const QString &name) {
  if (name.compare(QStringLiteral("neutral"), Qt::CaseInsensitive) == 0) return Preset::Neutral;
  if (name.compare(QStringLiteral("evening"), Qt::CaseInsensitive) == 0) return Preset::Evening;
  if (name.compare(QStringLiteral("pure-red"), Qt::CaseInsensitive) == 0 ||
      name.compare(QStringLiteral("purered"), Qt::CaseInsensitive) == 0) return Preset::PureRed;
  return std::nullopt;
}

QString presetName(Preset preset) {
  switch (preset) {
  case Preset::Neutral: return QStringLiteral("neutral");
  case Preset::Evening: return QStringLiteral("evening");
  case Preset::PureRed: return QStringLiteral("pure-red");
  }
  return QStringLiteral("unknown");
}

ColorGains gainsForWarmth(double warmth) {
  const double amount = clamp(warmth, 0.0, 1.0);
  if (amount == 0.0) return {1.0F, 1.0F, 1.0F};
  constexpr double redTailStart = 0.82;
  if (amount <= redTailStart) {
    const double progress = smoothstep(amount / redTailStart);
    const double kelvin = 6500.0 - (4500.0 * progress);
    return gainsForKelvin(kelvin);
  }

  const ColorGains base = gainsForKelvin(2000.0);
  const double progress = smoothstep((amount - redTailStart) / (1.0 - redTailStart));
  return {
      static_cast<float>(base.red + ((1.0F - base.red) * static_cast<float>(progress))),
      static_cast<float>(base.green * (1.0 - progress)),
      static_cast<float>(base.blue * (1.0 - progress)),
  };
}

std::optional<double> approximateKelvin(double warmth) {
  const double amount = clamp(warmth, 0.0, 1.0);
  if (amount > 0.82) return std::nullopt;
  return 6500.0 - (4500.0 * smoothstep(amount / 0.82));
}

ColorGains gainsForKelvin(double kelvin) {
  const double temperature = clamp(kelvin, 1667.0, 25000.0);
  if (std::abs(temperature - 6500.0) < 0.5) return {1.0F, 1.0F, 1.0F};

  const double x = temperature <= 4000.0
      ? (-0.2661239e9 / std::pow(temperature, 3.0))
          - (0.2343580e6 / std::pow(temperature, 2.0))
          + (0.8776956e3 / temperature) + 0.179910
      : (-3.0258469e9 / std::pow(temperature, 3.0))
          + (2.1070379e6 / std::pow(temperature, 2.0))
          + (0.2226347e3 / temperature) + 0.240390;

  const double y = temperature <= 2222.0
      ? (-1.1063814 * std::pow(x, 3.0)) - (1.34811020 * std::pow(x, 2.0))
          + (2.18555832 * x) - 0.20219683
      : temperature <= 4000.0
          ? (-0.9549476 * std::pow(x, 3.0)) - (1.37418593 * std::pow(x, 2.0))
              + (2.09137015 * x) - 0.16748867
          : (3.0817580 * std::pow(x, 3.0)) - (5.87338670 * std::pow(x, 2.0))
              + (3.75112997 * x) - 0.37001483;

  const double capitalX = x / y;
  const double capitalZ = (1.0 - x - y) / y;
  const double red = (3.2404542 * capitalX) - 1.5371385 - (0.4985314 * capitalZ);
  const double green = (-0.9692660 * capitalX) + 1.8760108 + (0.0415560 * capitalZ);
  const double blue = (0.0556434 * capitalX) - 0.2040259 + (1.0572252 * capitalZ);
  const double maximum = std::max({red, green, blue, 0.000001});
  return {clampChannel(red / maximum), clampChannel(green / maximum), clampChannel(blue / maximum)};
}

ColorMatrix matrixFor(const Settings &settings) {
  const ColorGains gains = gainsForWarmth(settings.warmth);
  const double brightness = clamp(settings.brightness, 0.10, 1.0);
  ColorMatrix matrix{};
  matrix.values = {
      brightness * static_cast<double>(gains.red), 0.0, 0.0,
      0.0, brightness * static_cast<double>(gains.green), 0.0,
      0.0, 0.0, brightness * static_cast<double>(gains.blue),
  };
  return matrix;
}

double presetWarmth(Preset preset) {
  switch (preset) {
  case Preset::Neutral: return 0.0;
  case Preset::Evening: return 0.62;
  case Preset::PureRed: return 1.0;
  }
  return 0.62;
}

bool finiteNonNegativeMatrix(const ColorMatrix &matrix) {
  return std::all_of(matrix.values.begin(), matrix.values.end(), [](double value) {
    return std::isfinite(value) && value >= 0.0;
  });
}

std::int32_t fixed24_8(double value) {
  const double clamped = std::max(0.0, std::min(value, static_cast<double>(std::numeric_limits<std::int32_t>::max()) / 256.0));
  return static_cast<std::int32_t>(std::llround(clamped * 256.0));
}

double fixed24_8ToDouble(std::int32_t value) {
  return static_cast<double>(value) / 256.0;
}

QString describeWarmth(double warmth) {
  if (warmth <= 0.0) return QStringLiteral("Neutral");
  if (warmth >= 1.0) return QStringLiteral("Pure Red");
  if (const auto kelvin = approximateKelvin(warmth); kelvin.has_value()) {
    return QStringLiteral("%1 K").arg(qRound(*kelvin));
  }
  return QStringLiteral("Toward Pure Red");
}

} // namespace ember
