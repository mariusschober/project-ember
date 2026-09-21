#include "core/Solar.h"

#include <QTimeZone>

#include <cmath>

namespace ember {

namespace {

constexpr double sunriseZenithDegrees = 90.833;

double degreesToRadians(double degrees) { return degrees * M_PI / 180.0; }
double radiansToDegrees(double radians) { return radians * 180.0 / M_PI; }

QDateTime eventDate(const QDate &startDate, double minutesAfterMidnight, const QTimeZone &timeZone) {
  if (!std::isfinite(minutesAfterMidnight)) return {};
  const auto totalSeconds = static_cast<qint64>(std::llround(minutesAfterMidnight * 60.0));
  const auto dayOffset = static_cast<qint64>(std::floor(static_cast<double>(totalSeconds) / 86400.0));
  const auto secondsInDay = totalSeconds - (dayOffset * 86400);
  const QDate date = startDate.addDays(static_cast<int>(dayOffset));
  if (!date.isValid() || secondsInDay < 0 || secondsInDay >= 86400) return {};
  const QTime time = QTime(0, 0).addSecs(static_cast<int>(secondsInDay));
  return QDateTime(date, time, timeZone);
}

} // namespace

SolarDay solarDay(const QDateTime &date, const Coordinate &coordinate, const QTimeZone &timeZone) {
  const QDate localDate = date.toTimeZone(timeZone).date();
  const QDateTime localNoon(localDate, QTime(12, 0), timeZone);
  const int dayOfYear = localDate.dayOfYear();
  const int daysInYear = localDate.daysInYear();
  const double fractionalYear = (2.0 * M_PI / static_cast<double>(daysInYear)) * static_cast<double>(dayOfYear - 1);
  const double equationOfTime = 229.18 * (
      0.000075 + (0.001868 * std::cos(fractionalYear)) - (0.032077 * std::sin(fractionalYear))
      - (0.014615 * std::cos(2.0 * fractionalYear)) - (0.040849 * std::sin(2.0 * fractionalYear)));
  const double declination = 0.006918 - (0.399912 * std::cos(fractionalYear))
      + (0.070257 * std::sin(fractionalYear)) - (0.006758 * std::cos(2.0 * fractionalYear))
      + (0.000907 * std::sin(2.0 * fractionalYear)) - (0.002697 * std::cos(3.0 * fractionalYear))
      + (0.00148 * std::sin(3.0 * fractionalYear));

  const double latitude = degreesToRadians(coordinate.latitude);
  const double zenith = degreesToRadians(sunriseZenithDegrees);
  const double cosineHourAngle = (std::cos(zenith) / (std::cos(latitude) * std::cos(declination)))
      - (std::tan(latitude) * std::tan(declination));
  if (cosineHourAngle > 1.0) return {SolarDayCondition::SunAlwaysBelow, {}, {}};
  if (cosineHourAngle < -1.0) return {SolarDayCondition::SunAlwaysAbove, {}, {}};

  const double hourAngleDegrees = radiansToDegrees(std::acos(cosineHourAngle));
  const double offsetMinutes = static_cast<double>(timeZone.offsetFromUtc(localNoon)) / 60.0;
  const double solarNoonMinutes = 720.0 - (4.0 * coordinate.longitude) - equationOfTime + offsetMinutes;
  const QDateTime sunrise = eventDate(localDate, solarNoonMinutes - (4.0 * hourAngleDegrees), timeZone);
  const QDateTime sunset = eventDate(localDate, solarNoonMinutes + (4.0 * hourAngleDegrees), timeZone);
  if (!sunrise.isValid() || !sunset.isValid()) return {SolarDayCondition::SunAlwaysBelow, {}, {}};
  return {SolarDayCondition::Normal, sunrise, sunset};
}

SolarSchedule solarSchedule(const QDateTime &date, const Coordinate &coordinate, const QTimeZone &timeZone) {
  const QDateTime now = date.toTimeZone(timeZone);
  const SolarDay today = solarDay(now, coordinate, timeZone);
  bool isNight = false;
  if (today.condition == SolarDayCondition::SunAlwaysAbove) {
    isNight = false;
  } else if (today.condition == SolarDayCondition::SunAlwaysBelow) {
    isNight = true;
  } else {
    isNight = now < today.sunrise || now >= today.sunset;
  }
  const SolarEventKind desiredKind = isNight ? SolarEventKind::Sunrise : SolarEventKind::Sunset;

  std::optional<SolarEvent> next;
  const QDate startDate = now.date();
  for (int offset = 0; offset <= 370; ++offset) {
    const QDate candidateDate = startDate.addDays(offset);
    const QDateTime candidateAtNoon(candidateDate, QTime(12, 0), timeZone);
    const SolarDay candidateDay = solarDay(candidateAtNoon, coordinate, timeZone);
    if (candidateDay.condition != SolarDayCondition::Normal) {
      const bool candidateNight = candidateDay.condition == SolarDayCondition::SunAlwaysBelow;
      // At the exact poles the standard hour-angle equation never produces a
      // normal sunrise/sunset day. Use the first local noon whose polar state
      // changes as a bounded scheduling boundary rather than preserving a
      // manual override forever.
      if (candidateNight != isNight && candidateAtNoon > now.addMSecs(500)) {
        next = SolarEvent{desiredKind, candidateAtNoon};
        break;
      }
      continue;
    }
    const QDateTime candidate = desiredKind == SolarEventKind::Sunrise ? candidateDay.sunrise : candidateDay.sunset;
    if (candidate > now.addMSecs(500)) {
      next = SolarEvent{desiredKind, candidate};
      break;
    }
  }
  return {isNight, next};
}

} // namespace ember
