import Darwin
import EmberCore
import Foundation

@main
@MainActor
enum EmberCoreChecks {
  private static var failures: [String] = []
  private static var checkCount = 0

  static func main() {
    checkColorCurve()
    checkGammaComposition()
    checkStateMachine()
    checkDisplayIdentity()
    checkSettingsMigration()
    checkRecoveryJournal()
    checkSolarCalculations()

    if failures.isEmpty {
      print("PASS: \(checkCount) Project Ember core checks")
    } else {
      for failure in failures {
        print("FAIL: \(failure)")
      }
      exit(1)
    }
  }

  private static func checkColorCurve() {
    expect(ColorCurve.gains(forWarmth: 0) == .neutral, "Neutral warmth must be exact")
    expect(ColorCurve.gains(forKelvin: 6500) == .neutral, "6500 K must be exact neutral")
    expect(
      ColorCurve.gains(forWarmth: 1) == ColorGains(red: 1, green: 0, blue: 0),
      "Pure Red endpoint must remove green and blue"
    )
    expect(
      ColorCurve.approximateKelvin(forWarmth: 1) == nil,
      "Pure Red must not claim a Kelvin value"
    )
    expect(ColorCurve.gains(forWarmth: -5) == .neutral, "Warmth lower bound must clamp")
    expect(
      ColorCurve.gains(forWarmth: 5) == ColorGains(red: 1, green: 0, blue: 0),
      "Warmth upper bound must clamp"
    )

    let samples = stride(from: 0.0, through: 1.0, by: 0.05).map(ColorCurve.gains(forWarmth:))
    let monotonic = zip(samples, samples.dropFirst()).allSatisfy {
      $0.1.blue <= $0.0.blue + 0.0001 && $0.1.green <= $0.0.green + 0.0001
    }
    expect(monotonic, "Warmth must remove blue and green monotonically")
  }

  private static func checkGammaComposition() {
    let baseline = GammaTable.identity(sampleCount: 256)
    expect(
      baseline.applying(gains: .neutral, apparentBrightness: 1) == baseline,
      "Neutral full-brightness transform must preserve the baseline"
    )

    let tiny = GammaTable.identity(sampleCount: 3)
    let transformed = tiny.applying(
      gains: ColorGains(red: 1, green: 0.5, blue: 0.25),
      apparentBrightness: 0.5
    )
    expect(transformed.red == [0, 0.25, 0.5], "Red gain and brightness must compose")
    expect(transformed.green == [0, 0.125, 0.25], "Green gain and brightness must compose")
    expect(transformed.blue == [0, 0.0625, 0.125], "Blue gain and brightness must compose")

    let resampled = GammaTable.identity(sampleCount: 4).resampled(to: 257)
    expect(resampled.sampleCount == 257, "Gamma resampling must use requested size")
    expect(
      resampled.red.first == 0 && resampled.red.last == 1,
      "Gamma resampling must preserve endpoints"
    )

    var current = baseline
    for _ in 0..<100 {
      current = current.applying(
        gains: ColorCurve.gains(forWarmth: 0.73),
        apparentBrightness: 0.42
      )
      current = baseline
    }
    expect(
      current.maximumAbsoluteDifference(from: baseline) == 0,
      "Repeated exact restore must have zero drift"
    )
  }

  private static func checkStateMachine() {
    var machine = DisplayStateMachine()
    expect(
      machine.transition(.enableRequested) == [
        .captureBaseline, .saveRecoveryRecord, .applyTransform,
      ],
      "Activation must journal before apply"
    )
    expect(machine.state == .activating, "Activation must enter activating state")
    _ = machine.transition(.activationSucceeded)
    expect(machine.state == .active, "Successful activation must become active")
    expect(
      machine.transition(.disableRequested) == [.stopBacklightGuard, .restoreBaseline],
      "Disable must stop guard and restore"
    )
    expect(machine.state == .restoring(.disable), "Disable must enter restoring state")
    expect(
      machine.transition(.restoreSucceeded) == [.clearRecoveryRecord],
      "Journal must clear only after restore"
    )
    expect(machine.state == .off, "Successful restore must become off")
  }

  private static func checkDisplayIdentity() {
    let first = identity(uuid: "A", serial: 10, unit: 1)
    let sameUUID = identity(uuid: "a", serial: 99, unit: 9)
    let changedUUID = identity(uuid: "B", serial: 10, unit: 7)
    let sameSerial = identity(uuid: nil, serial: 10, unit: 2)
    let sameUnit = identity(uuid: nil, serial: 0, unit: 1)
    let different = identity(uuid: nil, serial: 20, unit: 3)
    expect(first.matches(sameUUID), "Display UUID matching must be case-insensitive")
    expect(
      first.matches(changedUUID),
      "Display serial must survive a ColorSync UUID change"
    )
    expect(first.matches(sameSerial), "Display serial must provide a UUID fallback")
    expect(
      identity(uuid: nil, serial: 0, unit: 1).matches(sameUnit),
      "Display unit must provide a zero-serial fallback"
    )
    expect(!first.matches(different), "Different physical displays must not identity-match")
    expect(
      DisplayIdentity.legacy(displayID: 42).legacyDisplayID == 42,
      "Legacy recovery must retain its captured display ID"
    )
  }

  private static func checkSettingsMigration() {
    let legacyJSON = Data(
      #"{"warmth":0.4,"apparentBrightness":0.6,"filterEnabled":true,"backlightLockEnabled":false,"launchAtLogin":true}"#.utf8
    )
    do {
      let decoded = try JSONDecoder().decode(EmberSettings.self, from: legacyJSON)
      expect(!decoded.sunScheduleEnabled, "Legacy settings must default Sun scheduling to off")
      expect(decoded.automationOverride == nil, "Legacy settings must have no manual override")
      expect(decoded.launchAtLogin, "Legacy settings values must survive migration")

      let future = Date(timeIntervalSince1970: 2_000)
      var settings = EmberSettings(
        sunScheduleEnabled: true,
        automationOverride: AutomationOverride(filterEnabled: false, expiresAt: future)
      )
      settings.normalize(now: Date(timeIntervalSince1970: 1_000))
      expect(settings.automationOverride != nil, "A current manual override must be retained")
      settings.normalize(now: Date(timeIntervalSince1970: 3_000))
      expect(settings.automationOverride == nil, "An expired manual override must be removed")
    } catch {
      failures.append("Settings migration check threw: \(error.localizedDescription)")
    }
  }

  private static func checkRecoveryJournal() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let journal = RecoveryJournal(fileURL: directory.appendingPathComponent("recovery.json"))
    let builtIn = makeEntry(id: 1, uuid: "BUILT-IN", serial: 10, hardware: true)
    let external = makeEntry(id: 3, uuid: "EXTERNAL", serial: 20, hardware: false)
    let record = RecoveryRecord(
      appVersion: "check",
      displays: [builtIn, external],
      intendedSettings: .default
    )
    do {
      try journal.save(record)
      expect(journal.exists, "Recovery journal must exist after save")
      let loaded = try journal.load()
      expect(loaded?.schemaVersion == 2, "Recovery journal must encode schema v2")
      expect(loaded?.appVersion == record.appVersion, "Recovery app version must round-trip")
      expect(loaded?.displays == record.displays, "Every display baseline must round-trip")
      expect(
        loaded?.intendedSettings == record.intendedSettings,
        "Recovery settings must round-trip"
      )

      let legacy = LegacyRecoveryRecord(
        schemaVersion: 1,
        appVersion: "legacy",
        createdAt: Date(timeIntervalSince1970: 123),
        display: DisplayBaseline(displayID: 42, gammaTable: .identity(sampleCount: 8)),
        hardware: HardwareBaseline(brightness: 0.4, ambientLightCompensationEnabled: true),
        intendedSettings: .default
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .secondsSince1970
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .secondsSince1970
      let migrated = try decoder.decode(RecoveryRecord.self, from: encoder.encode(legacy))
      expect(migrated.schemaVersion == 1, "Legacy recovery must be recognized as schema v1")
      expect(migrated.displays.count == 1, "Legacy recovery must become one display entry")
      expect(
        migrated.displays.first?.identity.legacyDisplayID == 42,
        "Legacy recovery must preserve safe display resolution data"
      )

      try journal.clear()
      expect(!journal.exists, "Recovery journal must clear after restore")
      try? FileManager.default.removeItem(at: directory)
    } catch {
      failures.append("Recovery journal check threw: \(error.localizedDescription)")
    }
  }

  private static func checkSolarCalculations() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let equator = SolarCoordinate(latitude: 0, longitude: 0)
    let equinoxNoon = date(2026, 3, 20, 12, 0, calendar: utc)
    guard case .normal(let sunrise, let sunset) = SolarCalculator.dayCondition(
      for: equinoxNoon,
      coordinate: equator,
      calendar: utc
    ) else {
      expect(false, "Equatorial equinox must have sunrise and sunset")
      return
    }
    let sunriseHour = utc.component(.hour, from: sunrise)
    let sunsetHour = utc.component(.hour, from: sunset)
    expect((5...7).contains(sunriseHour), "Equatorial sunrise must be near 06:00")
    expect((17...19).contains(sunsetHour), "Equatorial sunset must be near 18:00")

    let noonSchedule = SolarCalculator.schedule(
      at: equinoxNoon,
      coordinate: equator,
      calendar: utc
    )
    expect(!noonSchedule.isNight, "Solar schedule must identify local noon as daytime")
    expect(noonSchedule.nextEvent?.kind == .sunset, "Noon must schedule sunset next")

    let midnight = date(2026, 3, 20, 0, 0, calendar: utc)
    let midnightSchedule = SolarCalculator.schedule(at: midnight, coordinate: equator, calendar: utc)
    expect(midnightSchedule.isNight, "Solar schedule must identify midnight as nighttime")
    expect(midnightSchedule.nextEvent?.kind == .sunrise, "Midnight must schedule sunrise next")

    let arctic = SolarCoordinate(latitude: 78.2, longitude: 15.6)
    let midsummer = date(2026, 6, 21, 12, 0, calendar: utc)
    let midwinter = date(2026, 12, 21, 12, 0, calendar: utc)
    expect(
      SolarCalculator.dayCondition(for: midsummer, coordinate: arctic, calendar: utc)
        == .sunAlwaysAboveHorizon,
      "Polar summer must be handled without a fake sunset"
    )
    expect(
      SolarCalculator.dayCondition(for: midwinter, coordinate: arctic, calendar: utc)
        == .sunAlwaysBelowHorizon,
      "Polar winter must be handled without a fake sunrise"
    )
    expect(
      SolarCalculator.schedule(at: midsummer, coordinate: arctic, calendar: utc).nextEvent?.kind
        == .sunset,
      "Polar summer must search forward for the next real sunset"
    )
    expect(
      SolarCalculator.schedule(at: midwinter, coordinate: arctic, calendar: utc).nextEvent?.kind
        == .sunrise,
      "Polar winter must search forward for the next real sunrise"
    )

    var canary = Calendar(identifier: .gregorian)
    canary.timeZone = TimeZone(identifier: "Atlantic/Canary")!
    let canaryDate = date(2026, 7, 17, 12, 0, calendar: canary)
    let canaryCondition = SolarCalculator.dayCondition(
      for: canaryDate,
      coordinate: SolarCoordinate(latitude: 28.1, longitude: -15.4),
      calendar: canary
    )
    if case .normal(let localSunrise, let localSunset) = canaryCondition {
      expect(
        (6...8).contains(canary.component(.hour, from: localSunrise)),
        "Canary sunrise must use the local time zone"
      )
      expect(
        (19...21).contains(canary.component(.hour, from: localSunset)),
        "Canary sunset must use daylight-saving time"
      )
    } else {
      expect(false, "Canary summer day must have normal solar events")
    }

    var newYork = Calendar(identifier: .gregorian)
    newYork.timeZone = TimeZone(identifier: "America/New_York")!
    let dstStart = date(2026, 3, 8, 12, 0, calendar: newYork)
    if case .normal(let dstSunrise, let dstSunset) = SolarCalculator.dayCondition(
      for: dstStart,
      coordinate: SolarCoordinate(latitude: 40.7, longitude: -74.0),
      calendar: newYork
    ) {
      expect(
        newYork.component(.day, from: dstSunrise) == 8
          && (6...8).contains(newYork.component(.hour, from: dstSunrise)),
        "DST-transition sunrise must remain on the correct local day"
      )
      expect(
        newYork.component(.day, from: dstSunset) == 8
          && (17...20).contains(newYork.component(.hour, from: dstSunset)),
        "DST-transition sunset must remain on the correct local day"
      )
    } else {
      expect(false, "New York DST transition day must have normal solar events")
    }
  }

  private static func identity(uuid: String?, serial: UInt32, unit: UInt32) -> DisplayIdentity {
    DisplayIdentity(
      uuid: uuid,
      vendorNumber: 100,
      modelNumber: 200,
      serialNumber: serial,
      unitNumber: unit,
      isBuiltIn: false
    )
  }

  private static func makeEntry(
    id: UInt32,
    uuid: String,
    serial: UInt32,
    hardware: Bool
  ) -> DisplayRecoveryEntry {
    let displayIdentity = identity(uuid: uuid, serial: serial, unit: id)
    return DisplayRecoveryEntry(
      identity: displayIdentity,
      display: DisplayBaseline(
        displayID: id,
        identity: displayIdentity,
        gammaTable: .identity(sampleCount: 8),
        capturedAt: Date(timeIntervalSince1970: 123)
      ),
      hardware: hardware
        ? HardwareBaseline(brightness: 0.4, ambientLightCompensationEnabled: true)
        : .empty
    )
  }

  private static func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    calendar: Calendar
  ) -> Date {
    calendar.date(
      from: DateComponents(
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
      )
    )!
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checkCount += 1
    if !condition() { failures.append(message) }
  }
}

private struct LegacyRecoveryRecord: Encodable {
  let schemaVersion: Int
  let appVersion: String
  let createdAt: Date
  let display: DisplayBaseline
  let hardware: HardwareBaseline
  let intendedSettings: EmberSettings
}
