import Foundation

public struct SolarCoordinate: Codable, Equatable, Sendable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = min(max(latitude, -90), 90)
    self.longitude = min(max(longitude, -180), 180)
  }

  public func rounded(to places: Int) -> SolarCoordinate {
    let scale = pow(10, Double(max(places, 0)))
    return SolarCoordinate(
      latitude: (latitude * scale).rounded() / scale,
      longitude: (longitude * scale).rounded() / scale
    )
  }
}

public struct CachedSolarLocation: Codable, Equatable, Sendable {
  public let coordinate: SolarCoordinate
  public let capturedAt: Date

  public init(coordinate: SolarCoordinate, capturedAt: Date = Date()) {
    self.coordinate = coordinate
    self.capturedAt = capturedAt
  }
}

public enum SolarEventKind: String, Codable, Equatable, Sendable {
  case sunrise
  case sunset
}

public struct SolarEvent: Codable, Equatable, Sendable {
  public let kind: SolarEventKind
  public let date: Date

  public init(kind: SolarEventKind, date: Date) {
    self.kind = kind
    self.date = date
  }
}

public enum SolarDayCondition: Equatable, Sendable {
  case normal(sunrise: Date, sunset: Date)
  case sunAlwaysAboveHorizon
  case sunAlwaysBelowHorizon
}

public struct SolarSchedule: Equatable, Sendable {
  public let isNight: Bool
  public let nextEvent: SolarEvent?

  public init(isNight: Bool, nextEvent: SolarEvent?) {
    self.isNight = isNight
    self.nextEvent = nextEvent
  }
}

public enum SolarCalculator {
  private static let sunriseZenithDegrees = 90.833

  public static func schedule(
    at date: Date,
    coordinate: SolarCoordinate,
    calendar sourceCalendar: Calendar = .autoupdatingCurrent
  ) -> SolarSchedule {
    let calendar = sourceCalendar
    let condition = dayCondition(for: date, coordinate: coordinate, calendar: calendar)
    let isNight: Bool
    switch condition {
    case .normal(let sunrise, let sunset):
      isNight = date < sunrise || date >= sunset
    case .sunAlwaysAboveHorizon:
      isNight = false
    case .sunAlwaysBelowHorizon:
      isNight = true
    }

    var nextEvent: SolarEvent?
    let nextKind: SolarEventKind = isNight ? .sunrise : .sunset
    let startOfToday = calendar.startOfDay(for: date)
    for offset in 0...370 {
      guard let candidateDay = calendar.date(byAdding: .day, value: offset, to: startOfToday)
      else { continue }
      guard case .normal(let sunrise, let sunset) = dayCondition(
        for: candidateDay,
        coordinate: coordinate,
        calendar: calendar
      ) else { continue }
      let candidate = nextKind == .sunrise
        ? SolarEvent(kind: .sunrise, date: sunrise)
        : SolarEvent(kind: .sunset, date: sunset)
      if candidate.date > date.addingTimeInterval(0.5) {
        nextEvent = candidate
        break
      }
    }

    return SolarSchedule(isNight: isNight, nextEvent: nextEvent)
  }

  public static func dayCondition(
    for date: Date,
    coordinate: SolarCoordinate,
    calendar sourceCalendar: Calendar = .autoupdatingCurrent
  ) -> SolarDayCondition {
    let calendar = sourceCalendar
    let startOfDay = calendar.startOfDay(for: date)
    guard let localNoon = calendar.date(byAdding: .hour, value: 12, to: startOfDay),
      let dayOfYear = calendar.ordinality(of: .day, in: .year, for: localNoon)
    else {
      return .sunAlwaysBelowHorizon
    }

    let daysInYear = calendar.range(of: .day, in: .year, for: localNoon)?.count ?? 365
    let fractionalYear =
      (2 * Double.pi / Double(daysInYear)) * (Double(dayOfYear - 1))
    let equationOfTime = 229.18
      * (
        0.000_075
          + (0.001_868 * cos(fractionalYear))
          - (0.032_077 * sin(fractionalYear))
          - (0.014_615 * cos(2 * fractionalYear))
          - (0.040_849 * sin(2 * fractionalYear))
      )
    let declination =
      0.006_918
      - (0.399_912 * cos(fractionalYear))
      + (0.070_257 * sin(fractionalYear))
      - (0.006_758 * cos(2 * fractionalYear))
      + (0.000_907 * sin(2 * fractionalYear))
      - (0.002_697 * cos(3 * fractionalYear))
      + (0.001_48 * sin(3 * fractionalYear))

    let latitude = degreesToRadians(coordinate.latitude)
    let zenith = degreesToRadians(sunriseZenithDegrees)
    let cosineHourAngle =
      (cos(zenith) / (cos(latitude) * cos(declination)))
      - (tan(latitude) * tan(declination))

    if cosineHourAngle > 1 { return .sunAlwaysBelowHorizon }
    if cosineHourAngle < -1 { return .sunAlwaysAboveHorizon }

    let hourAngleDegrees = radiansToDegrees(acos(cosineHourAngle))
    let offsetMinutes = Double(calendar.timeZone.secondsFromGMT(for: localNoon)) / 60
    let solarNoonMinutes =
      720 - (4 * coordinate.longitude) - equationOfTime + offsetMinutes
    let sunriseMinutes = solarNoonMinutes - (4 * hourAngleDegrees)
    let sunsetMinutes = solarNoonMinutes + (4 * hourAngleDegrees)

    guard
      let sunrise = eventDate(
        on: startOfDay,
        minutesAfterMidnight: sunriseMinutes,
        calendar: calendar
      ),
      let sunset = eventDate(
        on: startOfDay,
        minutesAfterMidnight: sunsetMinutes,
        calendar: calendar
      )
    else {
      return .sunAlwaysBelowHorizon
    }
    return .normal(sunrise: sunrise, sunset: sunset)
  }

  private static func eventDate(
    on startOfDay: Date,
    minutesAfterMidnight: Double,
    calendar: Calendar
  ) -> Date? {
    guard minutesAfterMidnight.isFinite else { return nil }
    let totalSeconds = Int((minutesAfterMidnight * 60).rounded())
    let dayOffset = Int(floor(Double(totalSeconds) / 86_400))
    let secondsInDay = totalSeconds - (dayOffset * 86_400)
    guard let eventDay = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) else {
      return nil
    }
    var components = calendar.dateComponents([.era, .year, .month, .day], from: eventDay)
    components.timeZone = calendar.timeZone
    components.hour = secondsInDay / 3_600
    components.minute = (secondsInDay % 3_600) / 60
    components.second = secondsInDay % 60
    return calendar.date(from: components)
  }

  private static func degreesToRadians(_ degrees: Double) -> Double {
    degrees * Double.pi / 180
  }

  private static func radiansToDegrees(_ radians: Double) -> Double {
    radians * 180 / Double.pi
  }
}
