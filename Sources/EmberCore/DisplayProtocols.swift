import Foundation

// MARK: - Injection seams (0.5.0)
//
// These protocols exist so the shipped orchestration can be exercised without
// mutating a real display. 0.4.0 declared a set of "test seams" here that
// nothing — not even the tests — conformed to, while DisplayCoordinator took
// concrete controllers; the safety-critical logic was therefore only reachable
// by running the destructive hardware self-tests. The types below are the seams
// the coordinator actually depends on, and `Tests/ProjectEmberTests` drives
// them with fakes.

/// A display Ember can address, with the identity used to match saved
/// baselines to physical panels.
public struct DisplayTarget: Equatable, Sendable {
  public let displayID: UInt32
  public let identity: DisplayIdentity
  public let gammaCapacity: UInt32

  public init(displayID: UInt32, identity: DisplayIdentity, gammaCapacity: UInt32) {
    self.displayID = displayID
    self.identity = identity
    self.gammaCapacity = gammaCapacity
  }

  /// A writable transfer table needs at least two samples. Enumeration already
  /// filters online/active/non-mirrored displays.
  public var supportsGamma: Bool { gammaCapacity >= 2 }
}

/// What the built-in backlight can actually do, discovered at runtime.
public struct BacklightCapability: Equatable, Sendable {
  public let brightnessControl: Bool
  public let ambientLightControl: Bool

  public init(brightnessControl: Bool, ambientLightControl: Bool) {
    self.brightnessControl = brightnessControl
    self.ambientLightControl = ambientLightControl
  }

  public static let unavailable = BacklightCapability(
    brightnessControl: false,
    ambientLightControl: false
  )
}

/// Colour-table control across every display Ember is allowed to mutate.
///
/// Main-actor isolated: every caller is the coordinator, and display I/O from
/// more than one thread is exactly the kind of data race Swift 6 is meant to
/// stop. Test fakes implement this on the main actor for the same reason.
@MainActor
public protocol DisplayControlling {
  /// Online, active, non-mirrored displays. Order is not significant.
  func displayTargets() throws -> [DisplayTarget]
  /// Reads and records a display's current table. Never mutates.
  func captureBaseline(for target: DisplayTarget) throws -> DisplayBaseline
  func readTable(displayID: UInt32, capacity: UInt32) throws -> GammaTable
  /// Writes the transform derived from `baseline` and verifies the readback.
  func apply(settings: EmberSettings, to baseline: DisplayBaseline) throws
  /// Writes the saved table and verifies the readback. Recovery entries are
  /// dropped only after this succeeds.
  func restoreVerified(_ baseline: DisplayBaseline) throws
  /// Read-only check: is the requested transform currently installed?
  func isTransformInstalled(settings: EmberSettings, baseline: DisplayBaseline) -> Bool
  /// Resolves a saved identity to a live display, or nil when it is offline.
  /// Ambiguous identities resolve to nil: no mutation without a unique match.
  func target(matching identity: DisplayIdentity) throws -> DisplayTarget?
  /// Identity keys that currently match more than one online display.
  func ambiguousIdentityKeys() throws -> Set<String>
  /// Last-resort system colour reset when no exact baseline can be applied.
  func forceColorSyncRestore()
}

/// The built-in panel's hardware backlight (private DisplayServices path).
/// Every entry point must refuse a display that is not built in.
@MainActor
public protocol BacklightControlling {
  func capability(for displayID: UInt32) -> BacklightCapability
  func captureBaseline(for displayID: UInt32) throws -> HardwareBaseline
  /// Takes over the backlight: captures nothing, so callers must have captured
  /// a restorable baseline first.
  func engage(on displayID: UInt32) throws
  /// Read-only drift check used by the guard; true means a write is needed.
  func needsEngagement(on displayID: UInt32) -> Bool
  func readBrightness(_ displayID: UInt32) throws -> Float
  func restore(_ baseline: HardwareBaseline, on displayID: UInt32) throws
}

@MainActor
public protocol JournalStore {
  var exists: Bool { get }
  func loadOutcome() -> JournalLoadOutcome
  func save(_ record: RecoveryRecord) throws
  func clear() throws
  @discardableResult
  func quarantineCorruptJournal() -> URL?
  /// Used when the primary journal cannot be decoded. Implementations move the
  /// unreadable file aside and return the last-known-good record, or nil when
  /// no usable backup exists. Never returns a record without proving it
  /// decodes, and never deletes the unreadable file.
  func recoverCorruptJournalFromBackup() -> RecoveryRecord?
}

@MainActor
public protocol SettingsPersisting {
  func load() -> EmberSettings
  func save(_ settings: EmberSettings) throws
}

extension RecoveryJournal: JournalStore {}
extension SettingsStore: SettingsPersisting {}
