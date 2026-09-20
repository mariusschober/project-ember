#pragma once

#include "core/Model.h"

#include <QDateTime>
#include <optional>

namespace ember {

enum class SolarEventKind { Sunrise, Sunset };

struct SolarEvent {
  SolarEventKind kind = SolarEventKind::Sunset;
  QDateTime time;
};

enum class SolarDayCondition { Normal, SunAlwaysAbove, SunAlwaysBelow };

struct SolarDay {
  SolarDayCondition condition = SolarDayCondition::SunAlwaysBelow;
  QDateTime sunrise;
  QDateTime sunset;
};

struct SolarSchedule {
  bool isNight = false;
  std::optional<SolarEvent> nextEvent;
};

SolarDay solarDay(const QDateTime &date, const Coordinate &coordinate, const QTimeZone &timeZone);
SolarSchedule solarSchedule(const QDateTime &date, const Coordinate &coordinate, const QTimeZone &timeZone);

} // namespace ember
