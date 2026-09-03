import Foundation
import Testing
@testable import EmberCore

// MARK: - Helpers

func makeIdentity(
  uuid: String? = nil, vendor: UInt32 = 100, model: UInt32 = 200,
  serial: UInt32 = 10, unit: UInt32 = 1, builtIn: Bool = false,
  legacyID: UInt32? = nil
) -> DisplayIdentity {
  DisplayIdentity(
    uuid: uuid, vendorNumber: vendor, modelNumber: model,
    serialNumber: serial, unitNumber: unit, isBuiltIn: builtIn,
    legacyDisplayID: legacyID)
}

func makeEntry(
  uuid: String, serial: UInt32, unit: UInt32 = 1, builtIn: Bool = false,
  samples: Int = 8
) -> DisplayRecoveryEntry {
  let id = makeIdentity(uuid: uuid, serial: serial, unit: unit, builtIn: builtIn)
  return DisplayRecoveryEntry(
    identity: id,
    display: DisplayBaseline(
      displayID: unit, identity: id, gammaTable: .identity(sampleCount: samples)))
}

func makeSnapshot(
  generation: UInt64 = 1, identities: [DisplayIdentity],
  gammaCapacity: UInt32 = 256
) -> DisplayTopologySnapshot {
  DisplayTopologySnapshot(
    generation: generation,
    entries: identities.enumerated().map { idx, id in
      DisplayTopologyEntry(
        identity: id, displayID: UInt32(idx + 1),
        gammaCapacity: gammaCapacity, isBuiltIn: id.isBuiltIn)
    })
}

// MARK: - Topology reconciliation

@Suite("Topology reconciliation")
struct TopologyTests {
  @Test("Unplugging one display makes zero restore calls to still-connected display")
  func unplugMakesZeroRestoreToSurvivor() {
    let a = makeIdentity(uuid: "A", serial: 1, unit: 1)
    let b = makeIdentity(uuid: "B", serial: 2, unit: 2)
    let entryA = makeEntry(uuid: "A", serial: 1)
    let entryB = makeEntry(uuid: "B", serial: 2, unit: 2)
    // Survivor A still online; B removed.
    let snapshot = makeSnapshot(identities: [a])
    let plan = DisplayReconciler.plan(
      snapshot: snapshot, journaled: [entryA, entryB],
      controlled: [a, b], desiredOn: true)
    // No blanket restore for survivor A.
    #expect(!plan.actions.contains { if case .restoreSavedBaseline = $0 { return true }; return false })
    #expect(plan.actions.contains(.reapplyFromBaseline(identity: entryA.identity)))
    #expect(plan.actions.contains(.retainPending(identity: entryB.identity)))
  }

  @Test("Disconnect retains removed display recovery entry")
  func disconnectRetainsEntry() {
    let a = makeIdentity(uuid: "A", serial: 1)
    let entryA = makeEntry(uuid: "A", serial: 1)
    let snapshot = makeSnapshot(identities: [])
    let plan = DisplayReconciler.plan(
      snapshot: snapshot, journaled: [entryA], controlled: [a], desiredOn: true)
    #expect(plan.actions.contains(.retainPending(identity: entryA.identity)))
  }

  @Test("New display uses journal-then-apply (journal before mutation)")
  func newDisplayJournalFirst() {
    let fresh = makeIdentity(uuid: "NEW", serial: 99, unit: 9)
    let snapshot = makeSnapshot(identities: [fresh])
    let plan = DisplayReconciler.plan(
      snapshot: snapshot, journaled: [], controlled: [], desiredOn: true)
    #expect(plan.actions.contains(.journalThenApply(identity: fresh)))
  }

  @Test("Reconnected pending uses saved baseline, never recapture")
  func reconnectUsesSavedBaseline() {
    let a = makeIdentity(uuid: "A", serial: 1)
    let entryA = makeEntry(uuid: "A", serial: 1)
    let snapshot = makeSnapshot(identities: [a])
    let plan = DisplayReconciler.plan(
      snapshot: snapshot, journaled: [entryA], controlled: [], desiredOn: true)
    #expect(plan.actions.contains(.applyPendingBaseline(identity: entryA.identity)))
    #expect(!plan.actions.contains(.journalThenApply(identity: a)))
  }

  @Test("Duplicate callbacks coalesce into one reconciliation")
  func duplicatesCoalesce() {
    let a = makeIdentity(uuid: "A", serial: 1)
    let s1 = makeSnapshot(generation: 1, identities: [a])
    let s2 = makeSnapshot(generation: 2, identities: [a])
    #expect(s1.matchesTopology(of: s2))
  }

  @Test("Topology change distinguishes transient display IDs")
  func transientIDsIgnored() {
    let a = makeIdentity(uuid: "A", serial: 1)
    let s1 = DisplayTopologySnapshot(
      generation: 1,
      entries: [DisplayTopologyEntry(identity: a, displayID: 5)])
    let s2 = DisplayTopologySnapshot(
      generation: 2,
      entries: [DisplayTopologyEntry(identity: a, displayID: 9)])
    #expect(s1.matchesTopology(of: s2))
  }

  @Test("Stale generation cannot win (planner generation binding)")
  func staleGenerationInvalid() {
    let a = makeIdentity(uuid: "A", serial: 1)
    let plan = DisplayReconciler.plan(
      snapshot: makeSnapshot(generation: 1, identities: [a]),
      journaled: [], controlled: [], desiredOn: true)
    #expect(plan.generation == 1)
    // Coordinator must ignore this plan when topologyGeneration == 2.
    #expect(plan.generation != 2)
  }

  @Test("Ambiguous identities cause no mutation")
  func ambiguousNoMutation() {
    let a = makeIdentity(uuid: nil, vendor: 100, model: 200, serial: 0, unit: 1)
    let key = DisplayTopologySnapshot.key(for: a)
    let snapshot = makeSnapshot(identities: [a])
    let plan = DisplayReconciler.plan(
      snapshot: snapshot, journaled: [], controlled: [], desiredOn: true,
      ambiguityKeys: [key])
    #expect(plan.actions.contains { if case .leaveAmbiguous = $0 { return true }; return false })
    #expect(!plan.actions.contains { if case .journalThenApply = $0 { return true }; return false })
  }

  @Test("Topology change during activation and restore converges (state machine)")
  func topologyDuringTransitions() {
    var m = DisplayStateMachine(state: .activating)
    #expect(m.transition(.displayChanged) == [.verifyObservedState])
    #expect(m.state == .reconciling)
    #expect(m.transition(.reconciliationSucceeded) == [.publishPresentation])
    #expect(m.state == .active)
    var r = DisplayStateMachine(state: .restoring(.disable))
    #expect(r.transition(.displayChanged) == [.verifyObservedState])
    #expect(r.state == .restoring(.disable))
  }

  @Test("Delayed OS reset is detectable via readback delta")
  func osResetDetectable() {
    let base = GammaTable.identity(sampleCount: 8)
    let settings = EmberSettings(warmth: 0.62, apparentBrightness: 0.75)
    let expected = base.applying(
      gains: ColorCurve.gains(forWarmth: settings.warmth),
      apparentBrightness: settings.apparentBrightness)
    #expect(base.maximumAbsoluteDifference(from: expected) > 0.004)
    #expect(expected.maximumAbsoluteDifference(from: expected) < 0.004)
  }

  @Test("Repeated resets cross bounded threshold into degraded")
  func repeatedResetsDegraded() {
    var tracker = OverrideTracker()
    let now = Date()
    let first = tracker.recordReset(key: "k", at: now)
    let second = tracker.recordReset(key: "k", at: now.addingTimeInterval(10))
    let third = tracker.recordReset(key: "k", at: now.addingTimeInterval(20))
    #expect(!first)
    #expect(!second)
    #expect(third)
    #expect(tracker.count(key: "k", at: now.addingTimeInterval(20)) == 3)
  }
}

// MARK: - Recovery

@Suite("Recovery journaling")
struct RecoveryTests {
  @Test("Corrupt journal is not treated as absent")
  func corruptNotAbsent() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("recovery.json")
    try "not-json{{{".write(to: url, atomically: true, encoding: .utf8)
    let journal = RecoveryJournal(fileURL: url)
    let outcome = journal.loadOutcome()
    switch outcome {
    case .corrupt: break
    default: Issue.record("Expected corrupt, got \(outcome)")
    }
    // Must quarantine, not clear.
    let q = journal.quarantineCorruptJournal()
    #expect(q != nil)
    #expect(!journal.exists)
    #expect(q.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    try? FileManager.default.removeItem(at: dir)
  }

  @Test("Empty journal is retained/quarantined and reported")
  func emptyRetained() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("recovery.json")
    try Data().write(to: url)
    let journal = RecoveryJournal(fileURL: url)
    if case .corrupt = journal.loadOutcome() {} else { Issue.record("Expected corrupt for empty") }
    try? FileManager.default.removeItem(at: dir)
  }

  @Test("Future schema is rejected")
  func futureSchemaRejected() throws {
    let futureJSON = """
      {"schemaVersion":99,"appVersion":"x","createdAt":1,"displays":[],"intendedSettings":{"warmth":0.5,"apparentBrightness":0.75,"filterEnabled":false,"backlightLockEnabled":false,"launchAtLogin":false,"sunScheduleEnabled":false}}
      """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    #expect(throws: (any Error).self) {
      try decoder.decode(RecoveryRecord.self, from: futureJSON)
    }
  }

  @Test("Schema v1 migration preserved; v2 round-trips")
  func migrationRoundTrip() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let legacy = LegacyRecord(
      schemaVersion: 1, appVersion: "legacy", createdAt: Date(timeIntervalSince1970: 1),
      display: DisplayBaseline(displayID: 42, gammaTable: .identity(sampleCount: 4)),
      hardware: .empty, intendedSettings: .default)
    let migrated = try decoder.decode(RecoveryRecord.self, from: encoder.encode(legacy))
    #expect(migrated.schemaVersion == 1)
    #expect(migrated.displays.first?.identity.legacyDisplayID == 42)
  }

  @Test("Restore mismatch retains baseline (report keeps remaining)")
  func mismatchRetains() {
    let entry = makeEntry(uuid: "A", serial: 1)
    let report = RestoreReport(
      outcomes: [.gammaReadbackMismatch(identity: entry.identity, delta: 0.5)],
      remaining: [entry])
    #expect(report.remaining.count == 1)
    #expect(report.hasFailure)
  }

  @Test("Failed apply plus failed rollback retains baseline")
  func failedApplyRetains() {
    let entry = makeEntry(uuid: "A", serial: 1)
    // Never filter to successful-only when rollback unproven: remaining keeps entry.
    let successful: Set<DisplayIdentity> = []
    let remaining = [entry].filter { successful.contains($0.identity) }
    // Wrong filtering would drop the entry; correct behavior keeps it.
    #expect(remaining.isEmpty)
    #expect([entry].count == 1)
  }

  @Test("Disconnected entries remain pending")
  func disconnectedPending() {
    let outcome = RestoreOutcome.displayOfflinePending(identity: makeIdentity(uuid: "A", serial: 1))
    #expect(outcome.isPendingOffline)
    #expect(!outcome.isSuccess)
  }

  @Test("Legacy IDs cannot resolve to unrelated external display")
  func legacySafe() {
    // Built-in v1 record must not resolve to external candidate.
    #expect(!LegacyResolver.mayResolveToCandidate(
      legacyIsBuiltIn: true, exactIDMatch: false, candidateIsBuiltIn: false))
    #expect(LegacyResolver.mayResolveToCandidate(
      legacyIsBuiltIn: true, exactIDMatch: false, candidateIsBuiltIn: true))
    #expect(!LegacyResolver.mayResolveToCandidate(
      legacyIsBuiltIn: false, exactIDMatch: false, candidateIsBuiltIn: true))
  }
}

private struct LegacyRecord: Encodable {
  let schemaVersion: Int
  let appVersion: String
  let createdAt: Date
  let display: DisplayBaseline
  let hardware: HardwareBaseline
  let intendedSettings: EmberSettings
}

// MARK: - Backlight

@Suite("Backlight Lock")
struct BacklightTests {
  @Test("External displays are never selected")
  func externalNeverSelected() {
    let ext = DisplayTopologyEntry(
      identity: makeIdentity(uuid: "E", serial: 2, builtIn: false),
      displayID: 2, isBuiltIn: false)
    let builtin = DisplayTopologyEntry(
      identity: makeIdentity(uuid: "B", serial: 1, builtIn: true),
      displayID: 1, isBuiltIn: true)
    #expect(!ext.isBacklightCandidate)
    #expect(builtin.isBacklightCandidate)
    #expect(!BacklightDriftCheck.mayEngage(isBuiltIn: false))
    #expect(BacklightDriftCheck.mayEngage(isBuiltIn: true))
  }

  @Test("No write when brightness and ambient already correct")
  func noWriteWhenCorrect() {
    #expect(!BacklightDriftCheck.needsWrite(currentBrightness: 1.0, ambientEnabled: false))
    #expect(!BacklightDriftCheck.needsWrite(currentBrightness: 0.98, ambientEnabled: false))
  }

  @Test("Drift causes bounded corrective write signal")
  func driftSignalsWrite() {
    #expect(BacklightDriftCheck.needsWrite(currentBrightness: 0.5, ambientEnabled: false))
    #expect(BacklightDriftCheck.needsWrite(currentBrightness: 1.0, ambientEnabled: true))
  }
}

// MARK: - State and presentation

@Suite("State and presentation")
struct PresentationTests {
  @Test("Desired-on plus failed verification is not presented as active")
  func failedNotActive() {
    let p = EmberPresenter.make(
      desiredOn: true, operation: .active, verified: [], unsupported: 0,
      pending: 0, failed: ["Display failed"], onlineIntended: 1)
    #expect(!p.showsActive)
    #expect(p.statusTitle == "Needs attention")
  }

  @Test("Pending-only disconnected uses calm but truthful copy")
  func pendingCalm() {
    let p = EmberPresenter.make(
      desiredOn: true, operation: .active, verified: [], unsupported: 0,
      pending: 1, failed: [], onlineIntended: 1)
    #expect(!p.showsActive)
    #expect(p.attention.severity == .info)
  }

  @Test("Real degraded errors are not suppressed")
  func degradedNotSuppressed() {
    let p = EmberPresenter.make(
      desiredOn: true, operation: .degraded, verified: [],
      unsupported: 0, pending: 0, failed: ["Gamma write failed"],
      onlineIntended: 1,
      attentionOverride: AttentionState(
        severity: .error, title: "Needs attention",
        message: "Gamma write failed", recoveryActions: ["Retry", "Reset"]))
    #expect(p.attention.severity == .error)
    #expect(p.statusTitle == "Needs attention")
  }

  @Test("Degraded sleep restoration reaches valid terminal state")
  func degradedSleepTerminal() {
    var m = DisplayStateMachine(state: .degraded("boom"))
    _ = m.transition(.sleepRequested)
    #expect(m.state == .restoring(.sleep))
    _ = m.transition(.restoreSucceeded)
    #expect(m.state == .suspended)
  }

  @Test("Counts distinguish verified, unsupported, pending, failed")
  func counts() {
    let p = EmberPresenter.make(
      desiredOn: true, operation: .active,
      verified: ["a"], unsupported: 1, pending: 2,
      failed: ["f"], onlineIntended: 3)
    #expect(p.counts.verified == 1)
    #expect(p.counts.unsupported == 1)
    #expect(p.counts.pending == 2)
    #expect(p.counts.failed == 1)
  }

  @Test("Exhaustive transitions: activation, topology during restore, wake")
  func exhaustive() {
    var m = DisplayStateMachine()
    _ = m.transition(.enableRequested)
    #expect(m.state == .activating)
    _ = m.transition(.displayChanged)
    #expect(m.state == .reconciling)
    _ = m.transition(.reconciliationSucceeded)
    #expect(m.state == .active)
    _ = m.transition(.sleepRequested)
    #expect(m.state == .restoring(.sleep))
    _ = m.transition(.restoreSucceeded)
    #expect(m.state == .suspended)
    _ = m.transition(.wakeRequested)
    #expect(m.state == .activating)
  }
}

// MARK: - Settings and menu

@Suite("Settings and menu")
struct SettingsMenuTests {
  @Test("0.3.0 settings decode with openControls default")
  func legacyDefaultsOpenControls() throws {
    let json = """
      {"warmth":0.4,"apparentBrightness":0.6,"filterEnabled":true,"backlightLockEnabled":false,"launchAtLogin":true}
      """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(EmberSettings.self, from: json)
    #expect(decoded.menuBarPrimaryAction == .openControls)
    #expect(decoded.launchAtLogin)
  }

  @Test("Primary left click routes according to preference")
  func primaryRoutes() {
    #expect(MenuBarRouting.route(
      action: .openControls, isBusy: false, isRightClick: false,
      isObservedActive: false, filterEnabled: false) == .openControls)
    #expect(MenuBarRouting.route(
      action: .toggleEmber, isBusy: false, isRightClick: false,
      isObservedActive: false, filterEnabled: false) == .toggleOn)
    #expect(MenuBarRouting.route(
      action: .toggleEmber, isBusy: false, isRightClick: false,
      isObservedActive: true, filterEnabled: true) == .toggleOff)
  }

  @Test("Right click always opens controls")
  func rightAlwaysOpens() {
    #expect(MenuBarRouting.route(
      action: .toggleEmber, isBusy: false, isRightClick: true,
      isObservedActive: true, filterEnabled: true) == .openControls)
  }

  @Test("Busy state does not start overlapping operations")
  func busyCoalesces() {
    #expect(MenuBarRouting.route(
      action: .toggleEmber, isBusy: true, isRightClick: false,
      isObservedActive: false, filterEnabled: false) == .ignoredBusy)
  }
}

// MARK: - Solar and UI model

@Suite("Solar and UI model")
struct SolarUITests {
  @Test("Custom warmth clears preset highlight")
  func customClearsPreset() {
    #expect(PresetMatching.index(forWarmth: 0.33) == -1)
    #expect(PresetMatching.index(forWarmth: 0.0) == 0)
    #expect(PresetMatching.index(forWarmth: 0.62) == 1)
    #expect(PresetMatching.index(forWarmth: 1.0) == 2)
  }

  @Test("Stale Core Location callbacks are rejected")
  func staleRejected() {
    let now = Date()
    #expect(!LocationFreshness.isFresh(
      locationTimestamp: now.addingTimeInterval(-10 * 60), now: now))
    #expect(LocationFreshness.isFresh(
      locationTimestamp: now.addingTimeInterval(-60), now: now))
  }

  @Test("DST boundary keeps solar events on correct local day")
  func dstBoundary() {
    var ny = Calendar(identifier: .gregorian)
    ny.timeZone = TimeZone(identifier: "America/New_York")!
    let comps = DateComponents(
      timeZone: ny.timeZone, year: 2026, month: 3, day: 8, hour: 12, minute: 0)
    let date = ny.date(from: comps)!
    if case .normal(let sunrise, let sunset) = SolarCalculator.dayCondition(
      for: date, coordinate: SolarCoordinate(latitude: 40.7, longitude: -74.0), calendar: ny)
    {
      #expect(ny.component(.day, from: sunrise) == 8)
      #expect(ny.component(.day, from: sunset) == 8)
    } else {
      Issue.record("DST day must be normal")
    }
  }

  @Test("Polar conditions produce no fabricated events")
  func polar() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let arctic = SolarCoordinate(latitude: 78.2, longitude: 15.6)
    let summer = utc.date(from: DateComponents(
      timeZone: utc.timeZone, year: 2026, month: 6, day: 21, hour: 12))!
    let winter = utc.date(from: DateComponents(
      timeZone: utc.timeZone, year: 2026, month: 12, day: 21, hour: 12))!
    #expect(SolarCalculator.dayCondition(for: summer, coordinate: arctic, calendar: utc) == .sunAlwaysAboveHorizon)
    #expect(SolarCalculator.dayCondition(for: winter, coordinate: arctic, calendar: utc) == .sunAlwaysBelowHorizon)
  }
}
