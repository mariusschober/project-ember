import Foundation

// MARK: - Test seams (0.4.0)
//
// Minimal indirection to make reconciliation deterministic in tests.
// No abstract framework — only the I/O boundaries the reconciler needs.

public struct EnumeratedDisplay: Equatable, Sendable {
  public let displayID: UInt32
  public let identity: DisplayIdentity
  public let gammaCapacity: UInt32
  public let isOnline: Bool
  public let isActive: Bool
  public let isMirrored: Bool

  public init(
    displayID: UInt32,
    identity: DisplayIdentity,
    gammaCapacity: UInt32,
    isOnline: Bool = true,
    isActive: Bool = true,
    isMirrored: Bool = false
  ) {
    self.displayID = displayID
    self.identity = identity
    self.gammaCapacity = gammaCapacity
    self.isOnline = isOnline
    self.isActive = isActive
    self.isMirrored = isMirrored
  }

  public var supportsGamma: Bool { gammaCapacity >= 2 && isOnline && isActive && !isMirrored }
}

public protocol DisplayEnumerator: Sendable {
  func enumerate() throws -> [EnumeratedDisplay]
  func target(matching identity: DisplayIdentity) throws -> EnumeratedDisplay?
}

public protocol GammaController: Sendable {
  func captureBaseline(for displayID: UInt32, identity: DisplayIdentity, capacity: UInt32) throws -> DisplayBaseline
  func readTable(displayID: UInt32, capacity: UInt32) throws -> GammaTable
  func write(_ table: GammaTable, displayID: UInt32, capacity: UInt32, identity: DisplayIdentity) throws
  func transformedTable(settings: EmberSettings, from baseline: GammaTable) -> GammaTable
}

public protocol HardwareBacklightController: Sendable {
  func captureBaseline(displayID: UInt32) throws -> HardwareBaseline
  func readBrightness(displayID: UInt32) throws -> Float
  func readAmbientEnabled(displayID: UInt32) throws -> Bool?
  func writeBrightness(_ value: Float, displayID: UInt32) throws
  func writeAmbientEnabled(_ value: Bool, displayID: UInt32) throws
}

public protocol JournalStore: Sendable {
  func loadOutcome() -> JournalLoadOutcome
  func save(_ record: RecoveryRecord) throws
  func clear() throws
  func quarantineCorruptJournal() -> URL?
  var exists: Bool { get }
}

extension RecoveryJournal: JournalStore {}

public protocol SettingsPersisting: Sendable {
  func load() -> EmberSettings
  func save(_ settings: EmberSettings) throws
}

public protocol Clock: Sendable {
  func now() -> Date
}

public struct SystemClock: Clock, Sendable {
  public init() {}
  public func now() -> Date { Date() }
}
