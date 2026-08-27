import Foundation

public struct AutomationOverride: Codable, Equatable, Sendable {
  public var filterEnabled: Bool
  public var expiresAt: Date

  public init(filterEnabled: Bool, expiresAt: Date) {
    self.filterEnabled = filterEnabled
    self.expiresAt = expiresAt
  }
}

public struct EmberSettings: Codable, Equatable, Sendable {
  public var warmth: Double
  public var apparentBrightness: Double
  public var filterEnabled: Bool
  public var backlightLockEnabled: Bool
  public var launchAtLogin: Bool
  public var sunScheduleEnabled: Bool
  public var automationOverride: AutomationOverride?

  public init(
    warmth: Double = 0.62,
    apparentBrightness: Double = 0.75,
    filterEnabled: Bool = false,
    backlightLockEnabled: Bool = false,
    launchAtLogin: Bool = false,
    sunScheduleEnabled: Bool = false,
    automationOverride: AutomationOverride? = nil
  ) {
    self.warmth = warmth.clamped(to: 0...1)
    self.apparentBrightness = apparentBrightness.clamped(to: 0.10...1)
    self.filterEnabled = filterEnabled
    self.backlightLockEnabled = backlightLockEnabled
    self.launchAtLogin = launchAtLogin
    self.sunScheduleEnabled = sunScheduleEnabled
    self.automationOverride = automationOverride
  }

  public static let `default` = EmberSettings()

  public mutating func normalize(now: Date = Date()) {
    warmth = warmth.clamped(to: 0...1)
    apparentBrightness = apparentBrightness.clamped(to: 0.10...1)
    if let automationOverride, automationOverride.expiresAt <= now {
      self.automationOverride = nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case warmth
    case apparentBrightness
    case filterEnabled
    case backlightLockEnabled
    case launchAtLogin
    case sunScheduleEnabled
    case automationOverride
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    warmth = try values.decodeIfPresent(Double.self, forKey: .warmth) ?? defaults.warmth
    apparentBrightness =
      try values.decodeIfPresent(Double.self, forKey: .apparentBrightness)
      ?? defaults.apparentBrightness
    filterEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .filterEnabled) ?? defaults.filterEnabled
    backlightLockEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .backlightLockEnabled)
      ?? defaults.backlightLockEnabled
    launchAtLogin =
      try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
    sunScheduleEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .sunScheduleEnabled)
      ?? defaults.sunScheduleEnabled
    automationOverride = try values.decodeIfPresent(
      AutomationOverride.self,
      forKey: .automationOverride
    )
    normalize()
  }
}

public enum EmberPreset: String, Codable, CaseIterable, Sendable {
  case neutral
  case evening
  case pureRed

  public var warmth: Double {
    switch self {
    case .neutral: 0
    case .evening: 0.62
    case .pureRed: 1
    }
  }
}

public struct ColorGains: Codable, Equatable, Sendable {
  public let red: Float
  public let green: Float
  public let blue: Float

  public init(red: Float, green: Float, blue: Float) {
    self.red = red.clamped(to: 0...1)
    self.green = green.clamped(to: 0...1)
    self.blue = blue.clamped(to: 0...1)
  }

  public static let neutral = ColorGains(red: 1, green: 1, blue: 1)
}

public struct HardwareBaseline: Codable, Equatable, Sendable {
  public var brightness: Float?
  public var ambientLightCompensationEnabled: Bool?

  public init(brightness: Float?, ambientLightCompensationEnabled: Bool?) {
    self.brightness = brightness
    self.ambientLightCompensationEnabled = ambientLightCompensationEnabled
  }

  public static let empty = HardwareBaseline(
    brightness: nil,
    ambientLightCompensationEnabled: nil
  )

  public var hasValues: Bool {
    brightness != nil || ambientLightCompensationEnabled != nil
  }
}

public struct DisplayIdentity: Codable, Equatable, Hashable, Sendable {
  public let uuid: String?
  public let vendorNumber: UInt32
  public let modelNumber: UInt32
  public let serialNumber: UInt32
  public let unitNumber: UInt32
  public let isBuiltIn: Bool
  public let legacyDisplayID: UInt32?

  public init(
    uuid: String?,
    vendorNumber: UInt32,
    modelNumber: UInt32,
    serialNumber: UInt32,
    unitNumber: UInt32,
    isBuiltIn: Bool,
    legacyDisplayID: UInt32? = nil
  ) {
    self.uuid = uuid?.lowercased()
    self.vendorNumber = vendorNumber
    self.modelNumber = modelNumber
    self.serialNumber = serialNumber
    self.unitNumber = unitNumber
    self.isBuiltIn = isBuiltIn
    self.legacyDisplayID = legacyDisplayID
  }

  public static func legacy(displayID: UInt32) -> DisplayIdentity {
    DisplayIdentity(
      uuid: nil,
      vendorNumber: 0,
      modelNumber: 0,
      serialNumber: 0,
      unitNumber: 0,
      isBuiltIn: true,
      legacyDisplayID: displayID
    )
  }

  public func matches(_ other: DisplayIdentity) -> Bool {
    if let uuid, let otherUUID = other.uuid {
      if uuid.caseInsensitiveCompare(otherUUID) == .orderedSame { return true }
      guard serialNumber != 0, other.serialNumber != 0 else { return false }
      return vendorNumber == other.vendorNumber
        && modelNumber == other.modelNumber
        && serialNumber == other.serialNumber
        && isBuiltIn == other.isBuiltIn
    }
    if serialNumber != 0, other.serialNumber != 0 {
      return vendorNumber == other.vendorNumber
        && modelNumber == other.modelNumber
        && serialNumber == other.serialNumber
        && isBuiltIn == other.isBuiltIn
    }
    return vendorNumber == other.vendorNumber
      && modelNumber == other.modelNumber
      && unitNumber == other.unitNumber
      && isBuiltIn == other.isBuiltIn
  }
}

public struct DisplayBaseline: Codable, Equatable, Sendable {
  public let displayID: UInt32
  public let identity: DisplayIdentity?
  public let gammaTable: GammaTable
  public let capturedAt: Date

  public init(
    displayID: UInt32,
    identity: DisplayIdentity? = nil,
    gammaTable: GammaTable,
    capturedAt: Date = Date()
  ) {
    self.displayID = displayID
    self.identity = identity
    self.gammaTable = gammaTable
    self.capturedAt = capturedAt
  }
}

public struct DisplayRecoveryEntry: Codable, Equatable, Sendable {
  public let identity: DisplayIdentity
  public let display: DisplayBaseline
  public var hardware: HardwareBaseline

  public init(
    identity: DisplayIdentity,
    display: DisplayBaseline,
    hardware: HardwareBaseline = .empty
  ) {
    self.identity = identity
    self.display = display
    self.hardware = hardware
  }
}

public struct RecoveryRecord: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let appVersion: String
  public let createdAt: Date
  public var displays: [DisplayRecoveryEntry]
  public let intendedSettings: EmberSettings

  public init(
    schemaVersion: Int = 2,
    appVersion: String,
    createdAt: Date = Date(),
    displays: [DisplayRecoveryEntry],
    intendedSettings: EmberSettings
  ) {
    self.schemaVersion = schemaVersion
    self.appVersion = appVersion
    self.createdAt = createdAt
    self.displays = displays
    self.intendedSettings = intendedSettings
  }

  public init(
    appVersion: String,
    createdAt: Date = Date(),
    display: DisplayBaseline,
    hardware: HardwareBaseline,
    intendedSettings: EmberSettings
  ) {
    let identity = display.identity ?? .legacy(displayID: display.displayID)
    self.init(
      appVersion: appVersion,
      createdAt: createdAt,
      displays: [
        DisplayRecoveryEntry(identity: identity, display: display, hardware: hardware)
      ],
      intendedSettings: intendedSettings
    )
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case appVersion
    case createdAt
    case displays
    case intendedSettings
    case display
    case hardware
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    appVersion = try values.decode(String.self, forKey: .appVersion)
    createdAt = try values.decode(Date.self, forKey: .createdAt)
    intendedSettings = try values.decode(EmberSettings.self, forKey: .intendedSettings)

    if let decodedDisplays = try values.decodeIfPresent(
      [DisplayRecoveryEntry].self,
      forKey: .displays
    ) {
      schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
      displays = decodedDisplays
    } else {
      let legacyDisplay = try values.decode(DisplayBaseline.self, forKey: .display)
      let legacyHardware = try values.decode(HardwareBaseline.self, forKey: .hardware)
      schemaVersion = 1
      displays = [
        DisplayRecoveryEntry(
          identity: legacyDisplay.identity ?? .legacy(displayID: legacyDisplay.displayID),
          display: legacyDisplay,
          hardware: legacyHardware
        )
      ]
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(2, forKey: .schemaVersion)
    try values.encode(appVersion, forKey: .appVersion)
    try values.encode(createdAt, forKey: .createdAt)
    try values.encode(displays, forKey: .displays)
    try values.encode(intendedSettings, forKey: .intendedSettings)
  }
}

public enum EmberError: LocalizedError, Equatable, Sendable {
  case noBuiltInDisplay
  case noCompatibleDisplay
  case displayUnavailable
  case displayIdentityMismatch
  case gammaReadFailed(Int32)
  case gammaWriteFailed(Int32)
  case gammaVerificationFailed
  case invalidGammaTable
  case backlightUnavailable
  case backlightReadFailed(Int32)
  case backlightWriteFailed(Int32)
  case ambientLightReadFailed(Int32)
  case ambientLightWriteFailed(Int32)
  case recoveryFailed(String)

  public var errorDescription: String? {
    switch self {
    case .noBuiltInDisplay:
      "No built-in display is currently available."
    case .noCompatibleDisplay:
      "No connected display accepts Project Ember's color controls."
    case .displayUnavailable:
      "The saved display is not currently connected."
    case .displayIdentityMismatch:
      "The connected display does not match the saved recovery baseline."
    case .gammaReadFailed(let code):
      "The current display color table could not be read (code \(code))."
    case .gammaWriteFailed(let code):
      "The display color table could not be updated (code \(code))."
    case .gammaVerificationFailed:
      "The display did not preserve the requested color table."
    case .invalidGammaTable:
      "The saved display color table is invalid."
    case .backlightUnavailable:
      "Hardware backlight control is unavailable on the connected displays."
    case .backlightReadFailed(let code):
      "The hardware brightness could not be read (code \(code))."
    case .backlightWriteFailed(let code):
      "The hardware brightness could not be changed (code \(code))."
    case .ambientLightReadFailed(let code):
      "Automatic brightness state could not be read (code \(code))."
    case .ambientLightWriteFailed(let code):
      "Automatic brightness state could not be changed (code \(code))."
    case .recoveryFailed(let message):
      "Display recovery failed: \(message)"
    }
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
