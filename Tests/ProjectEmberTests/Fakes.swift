import Foundation
import EmberCore

@testable import ProjectEmber

// MARK: - Fakes
//
// The point of these is to drive the *shipped* DisplayCoordinator logic without
// touching a real display. They are deliberately literal: each one records what
// it was asked to do and can be told to fail, so a test can assert on the app's
// behaviour rather than on a model of it.

@MainActor
final class FakeDisplay: DisplayControlling {
  // MARK: Configuration

  /// Displays that enumeration currently returns. Swap this to simulate a
  /// hot-plug or an unplug between calls.
  var targets: [DisplayTarget]

  /// Current table per display ID, used for readback and verification.
  var tables: [UInt32: GammaTable]

  /// Identities that match more than one online display.
  var ambiguousKeys: Set<String> = []

  /// When set, `apply` throws for these display IDs.
  var applyFailures: Set<UInt32> = []

  /// When set, `restoreVerified` throws for these display IDs.
  var restoreFailures: Set<UInt32> = []

  // MARK: Observations

  private(set) var colorSyncRestoreCount = 0
  private(set) var applyCount = 0
  private(set) var restoreCount = 0
  private(set) var readCount = 0
  private(set) var lastAppliedSettings: EmberSettings?

  init(targets: [DisplayTarget], tables: [UInt32: GammaTable] = [:]) {
    self.targets = targets
    self.tables = tables
  }

  // MARK: DisplayControlling

  func displayTargets() throws -> [DisplayTarget] { targets }

  func captureBaseline(for target: DisplayTarget) throws -> DisplayBaseline {
    let table = tables[target.displayID] ?? GammaTable.identity()
    return DisplayBaseline(
      displayID: target.displayID, identity: target.identity, gammaTable: table)
  }

  func readTable(displayID: UInt32, capacity: UInt32) throws -> GammaTable {
    readCount += 1
    return tables[displayID] ?? GammaTable.identity(sampleCount: Int(max(capacity, 2)))
  }

  func apply(settings: EmberSettings, to baseline: DisplayBaseline) throws {
    applyCount += 1
    if applyFailures.contains(baseline.displayID) { throw EmberError.gammaWriteFailed(-1) }
    lastAppliedSettings = settings
    let gains = ColorCurve.gains(forWarmth: settings.warmth)
    tables[baseline.displayID] = baseline.gammaTable.applying(
      gains: gains, apparentBrightness: settings.apparentBrightness)
  }

  func restoreVerified(_ baseline: DisplayBaseline) throws {
    restoreCount += 1
    if restoreFailures.contains(baseline.displayID) { throw EmberError.gammaVerificationFailed }
    tables[baseline.displayID] = baseline.gammaTable
  }

  func isTransformInstalled(settings: EmberSettings, baseline: DisplayBaseline) -> Bool {
    guard let current = tables[baseline.displayID] else { return false }
    let expected = baseline.gammaTable.applying(
      gains: ColorCurve.gains(forWarmth: settings.warmth),
      apparentBrightness: settings.apparentBrightness)
    return current.maximumAbsoluteDifference(from: expected) < 0.004
  }

  func target(matching identity: DisplayIdentity) throws -> DisplayTarget? {
    let candidates = targets.filter { identity.matches($0.identity) }
    guard candidates.count <= 1 else { return nil }
    return candidates.first
  }

  func ambiguousIdentityKeys() throws -> Set<String> { ambiguousKeys }

  func forceColorSyncRestore() { colorSyncRestoreCount += 1 }
}

@MainActor
final class FakeBacklight: BacklightControlling {
  var capabilityValue = BacklightCapability(
    brightnessControl: true, ambientLightControl: true)
  /// When true, `captureBaseline` throws, as it does when the private getter
  /// refuses to answer.
  var captureFails = false
  var brightness: Float = 0.65
  var ambientEnabled = true
  var engageNeeded = false

  private(set) var engageCount = 0
  private(set) var restoreCount = 0

  func capability(for displayID: UInt32) -> BacklightCapability { capabilityValue }

  func captureBaseline(for displayID: UInt32) throws -> HardwareBaseline {
    if captureFails { throw EmberError.backlightReadFailed(-1) }
    return HardwareBaseline(
      brightness: brightness, ambientLightCompensationEnabled: ambientEnabled)
  }

  func engage(on displayID: UInt32) throws {
    engageCount += 1
    brightness = 1
    ambientEnabled = false
  }

  func needsEngagement(on displayID: UInt32) -> Bool {
    engageNeeded || brightness < 0.97 || ambientEnabled
  }

  func readBrightness(_ displayID: UInt32) throws -> Float { brightness }

  func restore(_ baseline: HardwareBaseline, on displayID: UInt32) throws {
    restoreCount += 1
    if let value = baseline.brightness { brightness = value }
    if let ambient = baseline.ambientLightCompensationEnabled { ambientEnabled = ambient }
  }
}

/// In-memory journal. `quarantineCorruptJournal` clears `exists`, which is what
/// makes the "warning must survive an empty work list" regression reproducible.
@MainActor
final class FakeJournal: JournalStore {
  var exists: Bool
  var outcome: JournalLoadOutcome
  /// Record handed back by `recoverCorruptJournalFromBackup`, if any.
  var backupRecord: RecoveryRecord?

  private(set) var saveCount = 0
  private(set) var clearCount = 0
  private(set) var quarantineCount = 0
  private(set) var backupRecoveryCount = 0
  /// Most recent record handed to `save`, for asserting what was journaled.
  private(set) var lastSavedRecord: RecoveryRecord?

  init(exists: Bool = false, outcome: JournalLoadOutcome = .noJournal) {
    self.exists = exists
    self.outcome = outcome
  }

  func loadOutcome() -> JournalLoadOutcome { exists ? outcome : .noJournal }

  func save(_ record: RecoveryRecord) throws {
    saveCount += 1
    lastSavedRecord = record
    exists = true
    outcome = .loaded(record)
  }

  func clear() throws {
    clearCount += 1
    exists = false
    outcome = .noJournal
  }

  @discardableResult
  func quarantineCorruptJournal() -> URL? {
    quarantineCount += 1
    exists = false
    return URL(fileURLWithPath: "/tmp/fake-recovery.corrupt.json")
  }

  func recoverCorruptJournalFromBackup() -> RecoveryRecord? {
    backupRecoveryCount += 1
    guard let backupRecord else { return nil }
    quarantineCount += 1
    exists = false
    outcome = .loaded(backupRecord)
    return backupRecord
  }
}

@MainActor
final class FakeSettings: SettingsPersisting {
  var settings: EmberSettings
  private(set) var saveCount = 0

  init(_ settings: EmberSettings = .default) { self.settings = settings }

  func load() -> EmberSettings { settings }

  func save(_ settings: EmberSettings) throws {
    saveCount += 1
    self.settings = settings
  }
}

@MainActor
final class FakeLaunchAtLogin: LaunchAtLoginControlling {
  var isEnabled: Bool = false
  private(set) var setCount = 0

  func setEnabled(_ enabled: Bool) throws {
    setCount += 1
    isEnabled = enabled
  }
}

// MARK: - Helpers

enum Fixture {
  static func identity(
    uuid: String? = "11111111-2222-3333-4444-555555555555",
    serial: UInt32 = 1,
    unit: UInt32 = 0,
    builtIn: Bool = true
  ) -> DisplayIdentity {
    DisplayIdentity(
      uuid: uuid,
      vendorNumber: 0x610,
      modelNumber: 0xA032,
      serialNumber: serial,
      unitNumber: unit,
      isBuiltIn: builtIn
    )
  }

  static func target(
    _ id: UInt32 = 1, identity: DisplayIdentity, capacity: UInt32 = 1024
  ) -> DisplayTarget {
    DisplayTarget(displayID: id, identity: identity, gammaCapacity: capacity)
  }

  static func entry(for target: DisplayTarget) -> DisplayRecoveryEntry {
    DisplayRecoveryEntry(
      identity: target.identity,
      display: DisplayBaseline(
        displayID: target.displayID,
        identity: target.identity,
        gammaTable: GammaTable.identity()
      )
    )
  }
}

/// Spin the main actor until `condition` holds or the timeout expires, so the
/// coordinator's own Tasks and timers get a chance to run.
@MainActor
@discardableResult
func waitUntil(
  _ description: String,
  timeout: TimeInterval = 5,
  _ condition: () -> Bool
) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return true }
    try? await Task.sleep(nanoseconds: 20_000_000)
  }
  return condition()
}
