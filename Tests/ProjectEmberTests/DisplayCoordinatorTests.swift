import Foundation
import Testing

import EmberCore

@testable import ProjectEmber

/// Regression tests for the 0.5.0 correctness work.
///
/// Every test here drives the real `DisplayCoordinator` through the injected
/// fakes, so a failure means the shipped orchestration is wrong — not that a
/// model of it is.
@MainActor
private func makeCoordinator(
  displays: FakeDisplay,
  backlight: FakeBacklight = FakeBacklight(),
  journal: FakeJournal = FakeJournal(),
  settings: EmberSettings = .default,
  login: FakeLaunchAtLogin = FakeLaunchAtLogin()
) -> (DisplayCoordinator, FakeJournal, FakeSettings) {
  let store = FakeSettings(settings)
  let coordinator = DisplayCoordinator(
    gammaController: displays,
    backlightController: backlight,
    launchAtLoginController: login,
    settingsStore: store,
    recoveryJournal: journal,
    clock: Date.init
  )
  return (coordinator, journal, store)
}

private let builtIn = Fixture.identity()
private let external = Fixture.identity(
  uuid: "99999999-8888-7777-6666-555555555555", serial: 7, unit: 1, builtIn: false)

// MARK: - C1 / C2: identity bookkeeping

@Suite("Identity bookkeeping")
@MainActor
struct IdentityBookkeepingTests {

  @Test("Unplugging the only display stops Ember claiming it is active")
  func staleVerifiedIdentityIsPruned() async {
    let target = Fixture.target(1, identity: builtIn)
    let displays = FakeDisplay(targets: [target], tables: [1: GammaTable.identity()])
    let (coordinator, _, _) = makeCoordinator(
      displays: displays, settings: EmberSettings(filterEnabled: true))

    coordinator.start()
    #expect(coordinator.currentSnapshot().isObservedActive)
    #expect(coordinator.currentSnapshot().verifiedDisplayCount == 1)

    // Unplug: enumeration no longer returns the panel, and the display event
    // the OS sends for the removal arrives.
    displays.targets = []
    coordinator.handleDisplayEvent(displayID: 1, flags: 0, isBegin: false)

    let settled = await waitUntil("reconciliation after unplug") {
      coordinator.currentSnapshot().runtimeState != .reconciling
        && coordinator.currentSnapshot().verifiedDisplayCount == 0
    }
    #expect(settled)

    let snapshot = coordinator.currentSnapshot()
    #expect(snapshot.verifiedDisplayCount == 0)
    #expect(snapshot.isObservedActive == false)
    #expect(snapshot.statusTitle != "Ember is on")
    #expect(snapshot.pendingRestoreCount == 1, "the removed panel stays recoverable")
  }

  @Test("Unplugging one of two displays never accuses another display service")
  func offlineDisplayIsNotAnExternalOverride() async {
    let builtInTarget = Fixture.target(1, identity: builtIn)
    let externalTarget = Fixture.target(2, identity: external)
    let displays = FakeDisplay(
      targets: [builtInTarget, externalTarget],
      tables: [1: GammaTable.identity(), 2: GammaTable.identity()]
    )
    let (coordinator, _, _) = makeCoordinator(
      displays: displays, settings: EmberSettings(filterEnabled: true))

    coordinator.start()
    #expect(coordinator.currentSnapshot().verifiedDisplayCount == 2)

    displays.targets = [builtInTarget]
    coordinator.handleDisplayEvent(displayID: 2, flags: 0, isBegin: false)
    let settled = await waitUntil("reconciliation after unplug") {
      coordinator.currentSnapshot().verifiedDisplayCount == 1
    }
    #expect(settled)
    #expect(coordinator.currentSnapshot().runtimeState == .active)

    // Stand in for the two post-event passes plus several 30 s health ticks.
    for _ in 0..<4 {
      await coordinator.runVerificationPassForTesting(kind: "regression")
    }

    let snapshot = coordinator.currentSnapshot()
    #expect(coordinator.overrideStrikesForTesting(external) == 0)
    #expect(snapshot.attentionTitle == nil)
    #expect(
      !coordinator.diagnostics.formattedText().contains("Another display service"),
      "a removed cable must not be reported as another app fighting Ember"
    )
  }
}

// MARK: - C3: an empty work list is not success

@Suite("Reset and warning honesty")
@MainActor
struct ResetHonestyTests {

  @Test("A corrupt-journal warning survives a toggle with an empty work list")
  func corruptWarningIsNotWipedByAnEmptyRestore() async {
    let displays = FakeDisplay(targets: [], tables: [:])
    let journal = FakeJournal(exists: true, outcome: .corrupt(reason: "torn write"))
    let (coordinator, _, _) = makeCoordinator(displays: displays, journal: journal)

    coordinator.start()
    #expect(coordinator.currentSnapshot().attentionTitle == "Needs attention")
    #expect(displays.colorSyncRestoreCount == 1)

    // Toggling off now finds no journal and nothing to restore. 0.4.0 read that
    // as "everything is fine" and cleared the warning.
    coordinator.setFilterEnabled(false)

    #expect(
      coordinator.currentSnapshot().attentionTitle == "Needs attention",
      "an unreadable journal must not be silently forgotten"
    )
    #expect(coordinator.diagnostics.formattedText().contains("Nothing to restore"))
  }

  @Test("Reset with no recovery record still attempts the system fallback")
  func resetWithoutRecordAttemptsFallback() async {
    let displays = FakeDisplay(targets: [], tables: [:])
    let (coordinator, _, _) = makeCoordinator(displays: displays)

    coordinator.resetDisplayNow()

    #expect(
      displays.colorSyncRestoreCount == 1,
      "with nothing to restore the system fallback is the only real action"
    )
    let log = coordinator.diagnostics.formattedText()
    #expect(log.contains("No recovery record was available"))
    #expect(
      !log.contains("Manual display reset completed"),
      "0.4.0 claimed success while touching nothing"
    )
  }
}

// MARK: - M3 / M4: journal integrity

@Suite("Journal integrity")
@MainActor
struct JournalIntegrityTests {

  @Test("A corrupt journal restores from the last known good copy")
  func corruptJournalUsesBackup() async {
    let target = Fixture.target(1, identity: builtIn)
    let entry = Fixture.entry(for: target)
    let record = RecoveryRecord(
      appVersion: "0.5.0", displays: [entry], intendedSettings: .default)

    let displays = FakeDisplay(targets: [target], tables: [1: GammaTable.identity()])
    let journal = FakeJournal(exists: true, outcome: .corrupt(reason: "torn write"))
    journal.backupRecord = record
    let (coordinator, _, _) = makeCoordinator(displays: displays, journal: journal)

    coordinator.start()

    #expect(displays.restoreCount == 1, "the backup baseline is applied")
    #expect(displays.colorSyncRestoreCount == 0, "no fallback needed when a copy exists")
    #expect(coordinator.currentSnapshot().runtimeState == .off)
    #expect(coordinator.diagnostics.formattedText().contains("last known good journal"))
  }

  @Test("A reconnected display returns the machine to the off state")
  func pendingRecoveryLeavesDegraded() async {
    let target = Fixture.target(1, identity: builtIn)
    let entry = Fixture.entry(for: target)
    let record = RecoveryRecord(
      appVersion: "0.5.0", displays: [entry], intendedSettings: .default)

    let displays = FakeDisplay(targets: [], tables: [:])
    let journal = FakeJournal(exists: true, outcome: .loaded(record))
    let (coordinator, _, _) = makeCoordinator(displays: displays, journal: journal)

    coordinator.start()
    #expect(coordinator.currentSnapshot().pendingRestoreCount == 1)
    if case .degraded = coordinator.currentSnapshot().runtimeState {} else {
      Issue.record("a pending disconnected display should be degraded, not active")
    }

    // The panel comes back and the user (or a display event) retries.
    displays.targets = [target]
    displays.tables[1] = GammaTable.identity()
    coordinator.retryNow()

    #expect(coordinator.currentSnapshot().runtimeState == .off)
    #expect(coordinator.currentSnapshot().pendingRestoreCount == 0)
  }
}

// MARK: - M1: a stuck baseline must not block activation

@Suite("Activation resilience")
@MainActor
struct ActivationResilienceTests {

  @Test("A display whose restore is unverified can still be turned on from its saved baseline")
  func pendingBaselineIsReusedInsteadOfBlocking() async {
    let target = Fixture.target(1, identity: builtIn)
    let entry = Fixture.entry(for: target)
    let record = RecoveryRecord(
      appVersion: "0.5.0", displays: [entry], intendedSettings: .default)

    let displays = FakeDisplay(targets: [target], tables: [1: GammaTable.identity()])
    // Another service keeps overwriting the table, so restore verification
    // never settles — the case that used to make activation impossible.
    displays.restoreFailures = [1]

    let journal = FakeJournal(exists: true, outcome: .loaded(record))
    let (coordinator, _, _) = makeCoordinator(displays: displays, journal: journal)

    coordinator.start()
    #expect(coordinator.currentSnapshot().pendingRestoreCount == 1)

    coordinator.setFilterEnabled(true)
    let activated = await waitUntil("activation from a saved baseline") {
      coordinator.currentSnapshot().runtimeState == .active
    }

    #expect(activated, "0.4.0 refused to turn on at all in this state")
    #expect(coordinator.currentSnapshot().verifiedDisplayCount == 1)
    #expect(coordinator.diagnostics.formattedText().contains("reuses its saved baseline"))

    // The original baseline must still be journaled: the saved table is the
    // untouched identity ramp, not whatever the panel shows after applying.
    let saved = journal.lastSavedRecord?.displays.first?.display.gammaTable
    #expect(saved == GammaTable.identity(), "activation must never recapture over a pending baseline")
  }
}

// MARK: - M2: never change hardware that cannot be restored

@Suite("Backlight safety")
@MainActor
struct BacklightSafetyTests {

  @Test("Backlight Lock refuses to engage when no restorable baseline exists")
  func engageRefusedWithoutBaseline() async {
    let target = Fixture.target(1, identity: builtIn)
    let displays = FakeDisplay(targets: [target], tables: [1: GammaTable.identity()])
    let backlight = FakeBacklight()
    // The private getter refuses to answer, so no baseline can be captured.
    backlight.captureFails = true

    let (coordinator, _, _) = makeCoordinator(
      displays: displays,
      backlight: backlight,
      settings: EmberSettings(filterEnabled: true, backlightLockEnabled: true)
    )

    coordinator.start()
    coordinator.retryNow()
    _ = await waitUntil("reconciliation") { !coordinator.currentSnapshot().isBusy }

    #expect(
      backlight.engageCount == 0,
      "engaging would disable auto-brightness with nothing able to undo it"
    )
    if case .engaged = coordinator.currentSnapshot().backlightEngagement {
      Issue.record("Backlight Lock must not report engaged without a restorable baseline")
    }
  }
}

// MARK: - Live menu-bar routing and override back-off

@Suite("Menu-bar routing (live path)")
@MainActor
struct MenuBarRoutingTests {

  @Test("Primary click follows the saved preference")
  func primaryClickRoutesByPreference() async {
    let target = Fixture.target(1, identity: builtIn)
    let displays = FakeDisplay(targets: [target], tables: [1: GammaTable.identity()])

    var settings = EmberSettings(filterEnabled: false)
    settings.menuBarPrimaryAction = .openControls
    let (openCoordinator, _, _) = makeCoordinator(displays: displays, settings: settings)
    #expect(openCoordinator.handlePrimaryClick() == .openedControls)

    settings.menuBarPrimaryAction = .toggleEmber
    let (toggleCoordinator, _, _) = makeCoordinator(displays: displays, settings: settings)
    #expect(toggleCoordinator.handlePrimaryClick() == .toggledOn)

    _ = await waitUntil("activation") {
      toggleCoordinator.currentSnapshot().runtimeState == .active
    }
    #expect(toggleCoordinator.handlePrimaryClick() == .toggledOff)
    _ = await waitUntil("restore") {
      toggleCoordinator.currentSnapshot().runtimeState == .off
    }
  }
}

@Suite("External override back-off")
@MainActor
struct OverrideBackOffTests {

  @Test("Repeated resets trip a bounded pause that Retry clears")
  func repeatedResetsPauseAndRecover() async {
    let target = Fixture.target(1, identity: builtIn)
    let displays = FakeDisplay(targets: [target], tables: [1: GammaTable.identity()])
    let (coordinator, _, _) = makeCoordinator(
      displays: displays, settings: EmberSettings(filterEnabled: true))

    coordinator.start()
    _ = await waitUntil("activation") { coordinator.currentSnapshot().runtimeState == .active }

    // Another service keeps replacing the table: each pass detects it, repairs
    // it, and records a strike.
    for _ in 0..<3 {
      displays.tables[1] = GammaTable.identity()
      await coordinator.runVerificationPassForTesting(kind: "override")
    }

    #expect(coordinator.isOverridePausedForTesting, "the promised pause must be real")
    let snapshot = coordinator.currentSnapshot()
    #expect(snapshot.attentionTitle == "Needs attention")
    #expect(snapshot.attentionMessage?.contains("paused automatic reapplication") == true)

    // While paused the app stops fighting, so no further strikes accumulate.
    let strikesAtPause = coordinator.overrideStrikesForTesting(builtIn)
    displays.tables[1] = GammaTable.identity()
    await coordinator.runVerificationPassForTesting(kind: "paused")
    #expect(coordinator.overrideStrikesForTesting(builtIn) == strikesAtPause)

    // An explicit retry is the documented way out and must clear the pause.
    coordinator.retryNow()
    #expect(coordinator.isOverridePausedForTesting == false)
  }
}

// MARK: - Stage 5: energy behaviour

@Suite("Energy behaviour")
@MainActor
struct EnergyBehaviourTests {

  @Test("No repeating timer runs while Ember is off")
  func noTimersWhileOff() async {
    let target = Fixture.target(1, identity: builtIn)
    let displays = FakeDisplay(targets: [target], tables: [1: GammaTable.identity()])
    let (coordinator, _, _) = makeCoordinator(displays: displays)

    coordinator.start()
    #expect(coordinator.armedTimers.health == false)
    #expect(coordinator.armedTimers.backlightGuard == false)

    coordinator.setFilterEnabled(true)
    _ = await waitUntil("activation") { coordinator.currentSnapshot().runtimeState == .active }
    #expect(coordinator.armedTimers.health == true, "verification needs a timer while active")

    coordinator.setFilterEnabled(false)
    #expect(coordinator.armedTimers.health == false, "and must release it when Ember goes off")
  }

  @Test("A warmth change does not rewrite the recovery journal")
  func settingsFlushDoesNotRewriteJournal() async {
    let target = Fixture.target(1, identity: builtIn)
    let displays = FakeDisplay(targets: [target], tables: [1: GammaTable.identity()])
    let (coordinator, journal, store) = makeCoordinator(
      displays: displays, settings: EmberSettings(filterEnabled: true))

    coordinator.start()
    _ = await waitUntil("activation") { coordinator.currentSnapshot().runtimeState == .active }

    let savesAfterActivation = journal.saveCount
    let settingsSavesAfterActivation = store.saveCount

    coordinator.setWarmth(0.5)
    _ = await waitUntil("settings flush", timeout: 2) {
      store.saveCount > settingsSavesAfterActivation
    }

    #expect(store.saveCount > settingsSavesAfterActivation, "the preference is persisted")
    #expect(
      journal.saveCount == savesAfterActivation,
      "baselines did not change, so the ~33 KB record must not be rewritten"
    )
  }

  @Test("Timer intervals are shared with the hardware self-test")
  func sharedTimingConstants() {
    // The self-test waits on these; a change here must not silently desync it.
    #expect(EmberTiming.backlightGuardInterval == 30)
    #expect(EmberTiming.healthCheckInterval == 30)
    #expect(EmberTiming.transformCoalesceInterval == 0.05)
  }
}
