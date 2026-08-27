import AppKit
import CoreGraphics
import EmberCore
import Foundation

struct EmberSnapshot {
  let settings: EmberSettings
  let runtimeState: DisplayRuntimeState
  let statusTitle: String
  let statusDetail: String
  let displayAvailable: Bool
  let availableDisplayCount: Int
  let controlledDisplayCount: Int
  let unsupportedDisplayCount: Int
  let pendingRestoreCount: Int
  let backlightAvailable: Bool
  let ambientLightControlAvailable: Bool
  let solarStatusDetail: String
  let showLocationSettings: Bool
  let isBusy: Bool

  var warmthDescription: String {
    if let kelvin = ColorCurve.approximateKelvin(forWarmth: settings.warmth) {
      if settings.warmth < 0.01 { return "Neutral" }
      return "~\(Int(kelvin.rounded() / 50) * 50) K"
    }
    return "Pure Red"
  }
}

@MainActor
final class DisplayCoordinator: NSObject {
  var onSnapshot: ((EmberSnapshot) -> Void)?
  let diagnostics: DiagnosticLog

  private let gammaController: GammaDisplayController
  private let backlightController: DisplayServicesBacklightController
  private let launchAtLoginController: LaunchAtLoginController
  private let settingsStore: SettingsStore
  private let recoveryJournal: RecoveryJournal
  private let solarController: SolarScheduleController

  private var settings: EmberSettings
  private var machine = DisplayStateMachine()
  private var recoveryEntries: [DisplayRecoveryEntry] = []
  private var controlledIdentities: Set<DisplayIdentity> = []
  private var backlightIdentity: DisplayIdentity?
  nonisolated(unsafe) private var guardTimer: Timer?
  nonisolated(unsafe) private var pendingTransformTimer: Timer?
  private var consecutiveBacklightFailures = 0
  private var lastError: String?
  private var availableDisplayCount = 0
  private var compatibleDisplayCount = 0
  private var unsupportedDisplayCount = 0
  private var pendingRestoreCount = 0
  private var backlightCapability = DisplayServicesBacklightController.Capability(
    brightnessControl: false,
    ambientLightControl: false
  )
  private var resumeAfterWake = false
  private var solarSnapshot = SolarRuntimeSnapshot.inactive

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0"
  }

  init(
    gammaController: GammaDisplayController = GammaDisplayController(),
    backlightController: DisplayServicesBacklightController = DisplayServicesBacklightController(),
    launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController(),
    settingsStore: SettingsStore = SettingsStore(),
    recoveryJournal: RecoveryJournal = RecoveryJournal(
      fileURL: DisplayCoordinator.defaultRecoveryURL()
    ),
    solarController: SolarScheduleController = SolarScheduleController(),
    diagnostics: DiagnosticLog = DiagnosticLog()
  ) {
    self.gammaController = gammaController
    self.backlightController = backlightController
    self.launchAtLoginController = launchAtLoginController
    self.settingsStore = settingsStore
    self.recoveryJournal = recoveryJournal
    self.solarController = solarController
    self.diagnostics = diagnostics
    settings = settingsStore.load()
    super.init()

    solarController.onSnapshot = { [weak self] snapshot in
      self?.solarSnapshot = snapshot
      self?.publishSnapshot()
    }
    solarController.onSchedule = { [weak self] schedule in
      self?.handleSolarSchedule(schedule)
    }
    solarController.onAuthorizationFailure = { [weak self] message in
      guard let self else { return }
      settings.sunScheduleEnabled = false
      settings.automationOverride = nil
      lastError = message
      solarController.start(enabled: false)
      saveSettings()
      publishSnapshot()
    }
  }

  func start() {
    diagnostics.append("Project Ember \(appVersion) started")
    diagnostics.append("System: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    recoverIfNeeded()
    probeCapabilities()

    let actualLoginState = launchAtLoginController.isEnabled
    if settings.launchAtLogin != actualLoginState {
      settings.launchAtLogin = actualLoginState
      saveSettings()
    }

    if settings.sunScheduleEnabled {
      solarController.start(enabled: true)
    } else if settings.filterEnabled, machine.state == .off {
      performActivation()
    } else {
      publishSnapshot()
    }
  }

  func currentSnapshot() -> EmberSnapshot {
    // Visual QA force-active for snapshot testing when displays are asleep but we still want to show Pure Red hero
    if UserDefaults(suiteName: "app.projectember.visual-qa")?.bool(forKey: "forceActiveSnapshot") == true,
       CommandLine.arguments.contains("--snapshot-ui") {
      let count = max(compatibleDisplayCount, 1)
      // Use active status even if machine is off/degraded
      let status: (String, String) = ("Ember is on", "Active on \(count) \(count == 1 ? "display" : "displays").")
      return EmberSnapshot(
        settings: settings,
        runtimeState: .active,
        statusTitle: status.0,
        statusDetail: status.1,
        displayAvailable: compatibleDisplayCount > 0,
        availableDisplayCount: max(availableDisplayCount, count),
        controlledDisplayCount: count,
        unsupportedDisplayCount: 0,
        pendingRestoreCount: 0,
        backlightAvailable: backlightCapability.brightnessControl,
        ambientLightControlAvailable: backlightCapability.ambientLightControl,
        solarStatusDetail: solarStatusDetail(),
        showLocationSettings: false,
        isBusy: false
      )
    }
    let status: (String, String)
    switch machine.state {
    case .off:
      if let lastError {
        // Disconnected pending is tracked via pendingRestoreCount, not string parsing.
        // This avoids fragile substring checks and correctly distinguishes real errors
        // from background housekeeping for unplugged displays.
        let isPendingOnly = pendingRestoreCount > 0
          && lastError == Self.pendingRestoreMessage(count: pendingRestoreCount)
        if isPendingOnly {
          if compatibleDisplayCount > 0 {
            status = ("Ember is off", "Your displays look normal.")
          } else {
            status = ("No compatible display", "Connect a display that supports macOS color tables.")
          }
        } else {
          status = ("Needs attention", lastError)
        }
      } else if compatibleDisplayCount > 0 {
        status = (
          "Ready",
          Self.displayCountText(compatibleDisplayCount, suffix: "ready; original state untouched.")
        )
      } else {
        status = ("No compatible display", "Connect a display that supports macOS color tables.")
      }
    case .activating:
      status = ("Applying", "Saving every connected display state first…")
    case .active:
      let count = controlledIdentities.count
      if pendingRestoreCount > 0 {
        // Silent background: keep pending out of hero, show calm active
        status = (
          "Ember is on",
          "Active on \(count) \(count == 1 ? "display" : "displays")."
        )
      } else if unsupportedDisplayCount > 0 {
        status = (
          "Ember is on",
          "Active on \(count) of \(availableDisplayCount) displays; unsupported displays were left untouched."
        )
      } else {
        let lockText = settings.backlightLockEnabled ? " Hardware backlight is locked." : ""
        status = (
          "Ember is on",
          "Color and software brightness are active on \(count) \(count == 1 ? "display" : "displays").\(lockText)"
        )
      }
    case .restoring(let intent):
      status = (
        "Restoring",
        intent == .sleep
          ? "Preparing every display for sleep…" : "Returning every display to its saved state…"
      )
    case .suspended:
      status = ("Paused for sleep", "Ember will safely re-evaluate after wake.")
    case .degraded(let message):
      // Pending-only degraded (disconnected displays) should not show as warning.
      let isPendingOnly = pendingRestoreCount > 0
        && message == Self.pendingRestoreMessage(count: pendingRestoreCount)
      if isPendingOnly {
        status = ("Ember is off", "Your displays look normal.")
      } else {
        status = ("Needs attention", message)
      }
    }

    return EmberSnapshot(
      settings: settings,
      runtimeState: machine.state,
      statusTitle: status.0,
      statusDetail: status.1,
      displayAvailable: compatibleDisplayCount > 0,
      availableDisplayCount: availableDisplayCount,
      controlledDisplayCount: controlledIdentities.count,
      unsupportedDisplayCount: unsupportedDisplayCount,
      pendingRestoreCount: pendingRestoreCount,
      backlightAvailable: backlightCapability.brightnessControl,
      ambientLightControlAvailable: backlightCapability.ambientLightControl,
      solarStatusDetail: solarStatusDetail(),
      showLocationSettings: solarSnapshot.authorization == .denied
        || (solarSnapshot.authorization == .notDetermined
          && solarSnapshot.errorMessage != nil),
      isBusy: machine.state == .activating || Self.isRestoring(machine.state)
    )
  }

  func setFilterEnabled(_ enabled: Bool) {
    lastError = nil
    if settings.sunScheduleEnabled, let event = solarSnapshot.schedule?.nextEvent {
      settings.automationOverride = AutomationOverride(
        filterEnabled: enabled,
        expiresAt: event.date
      )
      diagnostics.append(
        "Manual override set until \(event.kind.rawValue) at \(event.date.formatted())"
      )
    }
    applyFilterState(enabled, persistDisabledState: !enabled)
  }

  func setWarmth(_ warmth: Double) {
    settings.warmth = min(max(warmth, 0), 1)
    settingsDidChange(reapply: true)
  }

  func setApparentBrightness(_ brightness: Double) {
    settings.apparentBrightness = min(max(brightness, 0.10), 1)
    settingsDidChange(reapply: true)
  }

  func applyPreset(_ preset: EmberPreset) {
    settings.warmth = preset.warmth
    settingsDidChange(reapply: true)
    diagnostics.append("Preset selected: \(preset.rawValue)")
  }

  func setBacklightLockEnabled(_ enabled: Bool) {
    guard !enabled || backlightCapability.brightnessControl else {
      lastError = EmberError.backlightUnavailable.localizedDescription
      settings.backlightLockEnabled = false
      saveSettings()
      publishSnapshot()
      return
    }

    if !settings.filterEnabled || machine.state != .active {
      settings.backlightLockEnabled = enabled
      saveSettings()
      publishSnapshot()
      return
    }

    guard let identity = backlightIdentity,
      let target = try? gammaController.target(matching: identity),
      let index = recoveryEntries.firstIndex(where: { $0.identity.matches(identity) })
    else {
      settings.backlightLockEnabled = false
      lastError = EmberError.backlightUnavailable.localizedDescription
      saveSettings()
      publishSnapshot()
      return
    }

    do {
      if enabled {
        let captured = try backlightController.captureBaseline(for: target.displayID)
        recoveryEntries[index].hardware = captured
        settings.backlightLockEnabled = true
        try rewriteRecoveryRecord()
        try backlightController.engage(on: target.displayID)
        startBacklightGuard()
        diagnostics.append("Backlight Lock engaged on the verified built-in display")
      } else {
        stopBacklightGuard()
        let hardware = recoveryEntries[index].hardware
        if hardware.hasValues {
          try backlightController.restore(hardware, on: target.displayID)
        }
        recoveryEntries[index].hardware = .empty
        settings.backlightLockEnabled = false
        try rewriteRecoveryRecord()
        diagnostics.append("Backlight Lock restored hardware settings")
      }
      lastError = nil
      saveSettings()
    } catch {
      diagnostics.append(
        "Backlight Lock change failed: \(error.localizedDescription)",
        level: "ERROR"
      )
      let hardware = recoveryEntries[index].hardware
      var restored = !hardware.hasValues
      if hardware.hasValues {
        do {
          try backlightController.restore(hardware, on: target.displayID)
          restored = true
        } catch {
          diagnostics.append(
            "Backlight rollback failed; recovery remains pending: \(error.localizedDescription)",
            level: "ERROR"
          )
        }
      }
      stopBacklightGuard()
      settings.backlightLockEnabled = false
      if restored { recoveryEntries[index].hardware = .empty }
      saveSettings()
      try? rewriteRecoveryRecord()
      lastError = restored
        ? error.localizedDescription
        : "Backlight Lock failed and hardware recovery remains pending."
    }
    publishSnapshot()
  }

  func setSunScheduleEnabled(_ enabled: Bool) {
    settings.sunScheduleEnabled = enabled
    settings.automationOverride = nil
    lastError = nil

    if enabled {
      do {
        try launchAtLoginController.setEnabled(true)
        settings.launchAtLogin = launchAtLoginController.isEnabled
      } catch {
        settings.launchAtLogin = launchAtLoginController.isEnabled
        lastError =
          "Sun schedule is active in this session, but Launch at login could not be enabled."
        diagnostics.append(
          "Sun schedule login registration failed: \(error.localizedDescription)",
          level: "WARN"
        )
      }
      saveSettings()
      solarController.setEnabledByUser(true)
      diagnostics.append("Sun schedule enabled")
    } else {
      solarController.setEnabledByUser(false)
      saveSettings()
      diagnostics.append("Sun schedule disabled; current display state retained")
      publishSnapshot()
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      try launchAtLoginController.setEnabled(enabled)
      settings.launchAtLogin = launchAtLoginController.isEnabled
      lastError = nil
      diagnostics.append("Launch at login set to \(settings.launchAtLogin)")
    } catch {
      settings.launchAtLogin = launchAtLoginController.isEnabled
      lastError = "Launch at login could not be changed: \(error.localizedDescription)"
      diagnostics.append(lastError ?? "Launch at login failed", level: "ERROR")
    }
    saveSettings()
    publishSnapshot()
  }

  func openLocationSettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
    ) else { return }
    NSWorkspace.shared.open(url)
  }

  func systemTimeChanged() {
    diagnostics.append("System clock or time zone changed; recalculating Sun schedule")
    solarController.refresh(forceLocation: false)
  }

  func willSleep() {
    pendingTransformTimer?.invalidate()
    pendingTransformTimer = nil
    // Handle all states that may have a pending recovery journal. The original
    // guard (`state == .active`) left `activating` and `degraded` with an
    // un-restored journal through sleep, risking a stuck gamma table after wake.
    let shouldRestore: Bool = {
      switch machine.state {
      case .active, .activating: return true
      case .degraded: return true
      case .restoring: return false
      case .suspended, .off: return false
      }
    }()
    guard shouldRestore else { return }
    diagnostics.append("System sleep detected")
    resumeAfterWake = settings.filterEnabled
    restoreDisplay(intent: .sleep, persistDisabledState: false)
  }

  func didWake() {
    diagnostics.append("System wake detected; scheduling a safe re-evaluation")
    NSObject.cancelPreviousPerformRequests(
      withTarget: self,
      selector: #selector(resumeAfterSystemWake),
      object: nil
    )
    perform(#selector(resumeAfterSystemWake), with: nil, afterDelay: 1.0)
  }

  func displayConfigurationChanged() {
    diagnostics.append("Display configuration changed; scheduling a safe refresh")
    NSObject.cancelPreviousPerformRequests(
      withTarget: self,
      selector: #selector(refreshForDisplayChange),
      object: nil
    )
    perform(#selector(refreshForDisplayChange), with: nil, afterDelay: 0.75)
  }

  func shutdown() {
    NSObject.cancelPreviousPerformRequests(withTarget: self)
    pendingTransformTimer?.invalidate()
    pendingTransformTimer = nil
    guard machine.state == .active || machine.state == .activating
      || Self.isDegraded(machine.state) || recoveryJournal.exists
    else { return }
    diagnostics.append("Application termination requested")
    restoreDisplay(intent: .terminate, persistDisabledState: false)
  }

  func resetDisplayNow() {
    pendingTransformTimer?.invalidate()
    pendingTransformTimer = nil
    stopBacklightGuard()
    let entries = recoveryEntries.isEmpty
      ? ((try? recoveryJournal.load())?.displays ?? [])
      : recoveryEntries
    var result = restore(entries)

    if result.hadOnlineFailure {
      gammaController.forceColorSyncRestore()
      diagnostics.append("ColorSync fallback applied after exact reset failure", level: "WARN")
      result.remaining.removeAll { entry in
        (try? gammaController.target(matching: entry.identity)) != nil
      }
    }

    controlledIdentities.removeAll()
    settings.filterEnabled = false
    settings.backlightLockEnabled = false
    recoveryEntries = result.remaining
    pendingRestoreCount = result.remaining.count
    saveSettings()

    if result.remaining.isEmpty {
      try? recoveryJournal.clear()
      machine = DisplayStateMachine()
      lastError = nil
      diagnostics.append("Manual display reset completed")
    } else {
      try? rewriteRecoveryRecord()
      let message = Self.pendingRestoreMessage(count: result.remaining.count)
      machine = DisplayStateMachine(state: .degraded(message))
      lastError = message
      diagnostics.append(message, level: "WARN")
    }
    probeCapabilities()
    publishSnapshot()
  }

  private func applyFilterState(
    _ enabled: Bool,
    persistDisabledState: Bool,
    preserveBacklightPreference: Bool = false
  ) {
    if enabled {
      settings.filterEnabled = true
      saveSettings()
      performActivation()
    } else if machine.state == .active || machine.state == .activating
      || Self.isDegraded(machine.state) || recoveryJournal.exists
    {
      restoreDisplay(
        intent: .disable,
        persistDisabledState: persistDisabledState,
        preserveBacklightPreference: preserveBacklightPreference
      )
    } else {
      settings.filterEnabled = false
      if persistDisabledState, !preserveBacklightPreference {
        settings.backlightLockEnabled = false
      }
      saveSettings()
      publishSnapshot()
    }
  }

  private func performActivation() {
    guard settings.filterEnabled else { return }
    guard machine.state == .off || machine.state == .suspended || Self.isDegraded(machine.state)
    else {
      if machine.state == .active { applyCurrentTransform() }
      return
    }

    _ = machine.transition(machine.state == .suspended ? .wakeRequested : .enableRequested)
    publishSnapshot()

    do {
      let priorEntries = (try recoveryJournal.load())?.displays ?? recoveryEntries
      let priorRecovery = restore(priorEntries)
      let pendingEntries = priorRecovery.remaining

      let targets = try gammaController.displayTargets()
      availableDisplayCount = targets.count
      compatibleDisplayCount = targets.filter(\.supportsGamma).count
      unsupportedDisplayCount = targets.count - compatibleDisplayCount

      var freshEntries: [DisplayRecoveryEntry] = []
      for target in targets where target.supportsGamma {
        if pendingEntries.contains(where: { $0.identity.matches(target.identity) }) {
          unsupportedDisplayCount += 1
          diagnostics.append(
            "Skipped display \(target.displayID) because exact prior recovery is still pending",
            level: "WARN"
          )
          continue
        }
        do {
          let baseline = try gammaController.captureBaseline(for: target)
          freshEntries.append(
            DisplayRecoveryEntry(identity: target.identity, display: baseline)
          )
        } catch {
          unsupportedDisplayCount += 1
          diagnostics.append(
            "Display \(target.displayID) baseline capture failed: \(error.localizedDescription)",
            level: "WARN"
          )
        }
      }
      guard !freshEntries.isEmpty else { throw EmberError.noCompatibleDisplay }

      backlightIdentity = nil
      backlightCapability = .init(brightnessControl: false, ambientLightControl: false)
      if settings.backlightLockEnabled {
        for index in freshEntries.indices {
          let entry = freshEntries[index]
          guard let target = try gammaController.target(matching: entry.identity) else { continue }
          let capability = backlightController.capability(for: target.displayID)
          if capability.brightnessControl {
            freshEntries[index].hardware = try backlightController.captureBaseline(
              for: target.displayID
            )
            backlightIdentity = entry.identity
            backlightCapability = capability
            break
          }
        }
        if backlightIdentity == nil {
          settings.backlightLockEnabled = false
          lastError = EmberError.backlightUnavailable.localizedDescription
          saveSettings()
        }
      }

      recoveryEntries = pendingEntries + freshEntries
      pendingRestoreCount = pendingEntries.count
      try rewriteRecoveryRecord()
      diagnostics.append(
        "Recovery journal saved for \(recoveryEntries.count) displays before mutation"
      )

      var successful: Set<DisplayIdentity> = []
      for entry in freshEntries {
        do {
          try gammaController.apply(settings: settings, to: entry.display)
          successful.insert(entry.identity)
        } catch {
          try? gammaController.restore(entry.display)
          unsupportedDisplayCount += 1
          diagnostics.append(
            "Display \(entry.display.displayID) apply verification failed: \(error.localizedDescription)",
            level: "ERROR"
          )
        }
      }
      guard !successful.isEmpty else { throw EmberError.noCompatibleDisplay }
      controlledIdentities = successful
      recoveryEntries = pendingEntries
        + freshEntries.filter { successful.contains($0.identity) }
      try rewriteRecoveryRecord()

      if settings.backlightLockEnabled,
        let identity = backlightIdentity,
        successful.contains(identity),
        let target = try gammaController.target(matching: identity)
      {
        do {
          try backlightController.engage(on: target.displayID)
        } catch {
          if let index = recoveryEntries.firstIndex(where: { $0.identity.matches(identity) }) {
            try? backlightController.restore(
              recoveryEntries[index].hardware,
              on: target.displayID
            )
            recoveryEntries[index].hardware = .empty
          }
          settings.backlightLockEnabled = false
          lastError = error.localizedDescription
          saveSettings()
          try? rewriteRecoveryRecord()
        }
      }

      _ = machine.transition(.activationSucceeded)
      if settings.backlightLockEnabled { startBacklightGuard() }
      resumeAfterWake = false
      if unsupportedDisplayCount == 0 { lastError = nil }
      diagnostics.append("Display transform active on \(successful.count) displays")
    } catch {
      diagnostics.append("Activation failed: \(error.localizedDescription)", level: "ERROR")
      stopBacklightGuard()
      let result = restore(recoveryEntries)
      recoveryEntries = result.remaining
      pendingRestoreCount = result.remaining.count
      controlledIdentities.removeAll()
      if result.remaining.isEmpty {
        try? recoveryJournal.clear()
      } else {
        try? rewriteRecoveryRecord()
      }
      _ = machine.transition(.activationFailed(error.localizedDescription))
      settings.filterEnabled = false
      settings.backlightLockEnabled = false
      saveSettings()
      lastError = error.localizedDescription
    }
    probeCapabilities(preserveUnsupportedCount: true)
    publishSnapshot()
  }

  private func restoreDisplay(
    intent: RestoreIntent,
    persistDisabledState: Bool,
    preserveBacklightPreference: Bool = false
  ) {
    pendingTransformTimer?.invalidate()
    pendingTransformTimer = nil
    switch intent {
    case .disable:
      _ = machine.transition(.disableRequested)
    case .sleep:
      _ = machine.transition(.sleepRequested)
    case .terminate:
      _ = machine.transition(.terminationRequested)
    case .recovery:
      machine = DisplayStateMachine(state: .restoring(.recovery))
    }
    publishSnapshot()
    stopBacklightGuard()

    let entries = recoveryEntries.isEmpty
      ? ((try? recoveryJournal.load())?.displays ?? [])
      : recoveryEntries
    let result = restore(entries)
    controlledIdentities.removeAll()
    recoveryEntries = result.remaining
    pendingRestoreCount = result.remaining.count

    if persistDisabledState {
      settings.filterEnabled = false
      if !preserveBacklightPreference {
        settings.backlightLockEnabled = false
      }
    }
    saveSettings()

    if result.remaining.isEmpty {
      _ = machine.transition(.restoreSucceeded)
      try? recoveryJournal.clear()
      backlightIdentity = nil
      lastError = nil
      diagnostics.append("Saved state restored for every available display")
    } else {
      let message = Self.pendingRestoreMessage(count: result.remaining.count)
      _ = machine.transition(.restoreFailed(message))
      lastError = message
      try? rewriteRecoveryRecord()
      diagnostics.append(message, level: "WARN")
    }
    probeCapabilities()
    publishSnapshot()
  }

  private func restore(_ entries: [DisplayRecoveryEntry]) -> RestoreResult {
    var remaining: [DisplayRecoveryEntry] = []
    var hadOnlineFailure = false
    for entry in entries {
      do {
        guard let target = try gammaController.target(matching: entry.identity) else {
          remaining.append(entry)
          continue
        }
        do {
          try gammaController.restore(entry.display)
          if entry.hardware.hasValues {
            try backlightController.restore(entry.hardware, on: target.displayID)
          }
        } catch {
          hadOnlineFailure = true
          remaining.append(entry)
          diagnostics.append(
            "Restore failed for display \(target.displayID): \(error.localizedDescription)",
            level: "ERROR"
          )
        }
      } catch {
        remaining.append(entry)
        diagnostics.append(
          "Display identity resolution failed during restore: \(error.localizedDescription)",
          level: "ERROR"
        )
      }
    }
    return RestoreResult(remaining: remaining, hadOnlineFailure: hadOnlineFailure)
  }

  private func settingsDidChange(reapply: Bool) {
    saveSettings()
    if recoveryJournal.exists { try? rewriteRecoveryRecord() }
    if reapply, machine.state == .active {
      _ = machine.transition(.settingsChanged)
      // Coalesce rapid slider events (continuous NSSlider) to at most ~20 Hz.
      // Without this, dragging the warmth/brightness slider fires
      // CGSetDisplayTransferByTable dozens of times per second plus a
      // readback verification each time, spiking CPU and causing visible
      // flicker. A short timer batches the final value.
      pendingTransformTimer?.invalidate()
      let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
        Task { @MainActor in self?.flushPendingTransform() }
      }
      timer.tolerance = 0.02
      RunLoop.main.add(timer, forMode: .common)
      pendingTransformTimer = timer
      // Publish interim snapshot so the slider value label updates instantly
      // even before the gamma table is re-applied.
      publishSnapshot()
    } else {
      publishSnapshot()
    }
  }

  private func flushPendingTransform() {
    pendingTransformTimer?.invalidate()
    pendingTransformTimer = nil
    guard machine.state == .active else { return }
    applyCurrentTransform()
  }

  private func applyCurrentTransform() {
    guard machine.state == .active else {
      publishSnapshot()
      return
    }
    var failed: Set<DisplayIdentity> = []
    for entry in recoveryEntries where controlledIdentities.contains(entry.identity) {
      do {
        try gammaController.apply(settings: settings, to: entry.display)
      } catch {
        try? gammaController.restore(entry.display)
        failed.insert(entry.identity)
        diagnostics.append(
          "Live transform failed for display \(entry.display.displayID): \(error.localizedDescription)",
          level: "ERROR"
        )
      }
    }
    controlledIdentities.subtract(failed)
    unsupportedDisplayCount += failed.count
    if controlledIdentities.isEmpty {
      machine = DisplayStateMachine(state: .degraded(EmberError.noCompatibleDisplay.localizedDescription))
      settings.filterEnabled = false
      saveSettings()
    }
    publishSnapshot()
  }

  private func recoverIfNeeded() {
    guard recoveryJournal.exists else { return }
    diagnostics.append("Unclean previous exit detected; starting multi-display recovery", level: "WARN")
    machine = DisplayStateMachine(state: .restoring(.recovery))

    do {
      guard let record = try recoveryJournal.load() else { return }
      let result = restore(record.displays)
      recoveryEntries = result.remaining
      pendingRestoreCount = result.remaining.count
      settings.filterEnabled = false
      settings.backlightLockEnabled = false
      saveSettings()

      if result.remaining.isEmpty {
        try recoveryJournal.clear()
        machine = DisplayStateMachine()
        lastError = nil
        diagnostics.append("Crash recovery completed; Ember stayed off for safety")
      } else {
        try rewriteRecoveryRecord()
        let message = Self.pendingRestoreMessage(count: result.remaining.count)
        machine = DisplayStateMachine(state: .degraded(message))
        lastError = message
        diagnostics.append(message, level: "WARN")
      }
    } catch {
      machine = DisplayStateMachine(state: .degraded(error.localizedDescription))
      lastError = "Previous display state could not be fully restored: \(error.localizedDescription)"
      diagnostics.append(lastError ?? "Recovery failed", level: "ERROR")
    }
  }

  private func recoverPendingDisplaysIfPossible() {
    guard recoveryJournal.exists, machine.state != .active, machine.state != .activating else {
      return
    }
    do {
      guard let record = try recoveryJournal.load() else { return }
      let result = restore(record.displays)
      recoveryEntries = result.remaining
      pendingRestoreCount = result.remaining.count
      if result.remaining.isEmpty {
        try recoveryJournal.clear()
        machine = DisplayStateMachine()
        lastError = nil
        diagnostics.append("A reconnected display completed its pending recovery")
      } else {
        try rewriteRecoveryRecord()
        let message = Self.pendingRestoreMessage(count: result.remaining.count)
        machine = DisplayStateMachine(state: .degraded(message))
        lastError = message
      }
    } catch {
      lastError = error.localizedDescription
      diagnostics.append("Pending recovery retry failed: \(error.localizedDescription)", level: "ERROR")
    }
  }

  private func probeCapabilities(preserveUnsupportedCount: Bool = false) {
    do {
      let targets = try gammaController.displayTargets()
      availableDisplayCount = targets.count
      compatibleDisplayCount = targets.filter(\.supportsGamma).count
      if !preserveUnsupportedCount {
        unsupportedDisplayCount = targets.count - compatibleDisplayCount
      }
      backlightIdentity = nil
      backlightCapability = .init(brightnessControl: false, ambientLightControl: false)
      for target in targets where target.supportsGamma {
        let capability = backlightController.capability(for: target.displayID)
        if capability.brightnessControl {
          backlightIdentity = target.identity
          backlightCapability = capability
          break
        }
      }
      diagnostics.append(
        "Capabilities: online=\(availableDisplayCount), gamma=\(compatibleDisplayCount), backlight=\(backlightCapability.brightnessControl)"
      )
    } catch {
      availableDisplayCount = 0
      compatibleDisplayCount = 0
      unsupportedDisplayCount = 0
      backlightIdentity = nil
      backlightCapability = .init(brightnessControl: false, ambientLightControl: false)
      lastError = error.localizedDescription
      diagnostics.append("Capability probe failed: \(error.localizedDescription)", level: "ERROR")
    }
  }

  private func rewriteRecoveryRecord() throws {
    guard !recoveryEntries.isEmpty else {
      try recoveryJournal.clear()
      return
    }
    let record = RecoveryRecord(
      appVersion: appVersion,
      displays: recoveryEntries,
      intendedSettings: settings
    )
    try recoveryJournal.save(record)
  }

  private func startBacklightGuard() {
    stopBacklightGuard()
    consecutiveBacklightFailures = 0
    // Reduced from 1 Hz to 0.2 Hz (5 s) to cut 80% of wakeups while still correcting
    // external brightness changes within a few seconds. Block-based timer avoids
    // the retain-cycle of the target/selector pattern and allows tolerance.
    let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.maintainBacklightLock() }
    }
    timer.tolerance = 1.0
    RunLoop.main.add(timer, forMode: .common)
    guardTimer = timer
  }

  private func stopBacklightGuard() {
    guardTimer?.invalidate()
    guardTimer = nil
    consecutiveBacklightFailures = 0
  }

  deinit {
    if Thread.isMainThread {
      guardTimer?.invalidate()
      pendingTransformTimer?.invalidate()
    } else {
      DispatchQueue.main.sync {
        self.guardTimer?.invalidate()
        self.pendingTransformTimer?.invalidate()
      }
    }
  }

  private func maintainBacklightLock() {
    guard settings.backlightLockEnabled,
      machine.state == .active,
      let identity = backlightIdentity,
      let target = try? gammaController.target(matching: identity)
    else {
      stopBacklightGuard()
      return
    }

    do {
      try backlightController.engage(on: target.displayID)
      consecutiveBacklightFailures = 0
    } catch {
      consecutiveBacklightFailures += 1
      diagnostics.append(
        "Backlight guard attempt \(consecutiveBacklightFailures) failed: \(error.localizedDescription)",
        level: "WARN"
      )
      if consecutiveBacklightFailures >= 3 {
        stopBacklightGuard()
        if let index = recoveryEntries.firstIndex(where: { $0.identity.matches(identity) }) {
          do {
            try backlightController.restore(
              recoveryEntries[index].hardware,
              on: target.displayID
            )
            recoveryEntries[index].hardware = .empty
          } catch {
            diagnostics.append(
              "Backlight guard rollback failed: \(error.localizedDescription)",
              level: "ERROR"
            )
          }
        }
        settings.backlightLockEnabled = false
        saveSettings()
        try? rewriteRecoveryRecord()
        lastError = "Backlight Lock stopped after three system-level write failures."
        publishSnapshot()
      }
    }
  }

  private func handleSolarSchedule(_ schedule: SolarSchedule) {
    guard settings.sunScheduleEnabled else { return }
    let now = Date()
    let desiredState: Bool
    if let override = settings.automationOverride, override.expiresAt > now {
      desiredState = override.filterEnabled
    } else {
      settings.automationOverride = nil
      desiredState = schedule.isNight
    }

    let runtimeIsActive = machine.state == .active
    if desiredState != runtimeIsActive || settings.filterEnabled != desiredState {
      diagnostics.append(
        "Sun schedule reconciled to \(desiredState ? "night" : "day") state"
      )
      applyFilterState(
        desiredState,
        persistDisabledState: !desiredState,
        preserveBacklightPreference: !desiredState
      )
    } else {
      saveSettings()
      publishSnapshot()
    }
  }

  private func solarStatusDetail() -> String {
    guard settings.sunScheduleEnabled else {
      if solarSnapshot.authorization == .denied,
        let message = solarSnapshot.errorMessage
      {
        return message
      }
      return "Turns Ember on at sunset and restores it at sunrise."
    }
    if !settings.launchAtLogin {
      return "Launch at login is off; transitions can be missed while Ember is closed."
    }
    if let message = solarSnapshot.errorMessage { return message }
    if solarSnapshot.isRefreshing, solarSnapshot.schedule == nil {
      return "Getting an approximate location…"
    }
    if let override = settings.automationOverride,
      override.expiresAt > Date(),
      let event = solarSnapshot.schedule?.nextEvent
    {
      return "Manual override until \(Self.eventDescription(event, includePrefix: false))."
    }
    if let event = solarSnapshot.schedule?.nextEvent {
      return "Next: \(Self.eventDescription(event, includePrefix: true))."
    }
    return "Waiting for the next local solar transition."
  }

  @objc private func resumeAfterSystemWake() {
    probeCapabilities()
    if settings.sunScheduleEnabled {
      solarController.refresh(forceLocation: false)
    } else if resumeAfterWake, settings.filterEnabled {
      performActivation()
    }
    resumeAfterWake = false
  }

  @objc private func refreshForDisplayChange() {
    if machine.state == .active {
      let shouldResume = settings.filterEnabled
      restoreDisplay(intent: .sleep, persistDisabledState: false)
      probeCapabilities()
      if shouldResume { performActivation() }
    } else {
      recoverPendingDisplaysIfPossible()
      probeCapabilities()
      if settings.sunScheduleEnabled {
        solarController.refresh(forceLocation: false)
      }
      publishSnapshot()
    }
  }

  private func saveSettings() {
    do {
      try settingsStore.save(settings)
    } catch {
      lastError = "Settings could not be saved: \(error.localizedDescription)"
      diagnostics.append(lastError ?? "Settings save failed", level: "ERROR")
    }
  }

  private func publishSnapshot() {
    onSnapshot?(currentSnapshot())
  }

  private static func defaultRecoveryURL() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return
      base
      .appendingPathComponent("Project Ember", isDirectory: true)
      .appendingPathComponent("display-recovery-v1.json")
  }

  private static func displayCountText(_ count: Int, suffix: String) -> String {
    "\(count) compatible \(count == 1 ? "display" : "displays") \(suffix)"
  }

  private static func pendingRestoreMessage(count: Int) -> String {
    "Ember saved your original colors for \(count) display(s) you unplugged — they’ll be restored when you reconnect."
  }

  private static func eventDescription(_ event: SolarEvent, includePrefix: Bool) -> String {
    let calendar = Calendar.autoupdatingCurrent
    let relativeDay: String
    if calendar.isDateInToday(event.date) {
      relativeDay = "today"
    } else if calendar.isDateInTomorrow(event.date) {
      relativeDay = "tomorrow"
    } else {
      relativeDay = event.date.formatted(date: .abbreviated, time: .omitted)
    }
    let time = event.date.formatted(date: .omitted, time: .shortened)
    let name = event.kind == .sunrise ? "sunrise" : "sunset"
    if includePrefix {
      return "\(name.capitalized) \(relativeDay) at \(time)"
    }
    return "\(name) \(relativeDay) at \(time)"
  }

  private static func isRestoring(_ state: DisplayRuntimeState) -> Bool {
    if case .restoring = state { return true }
    return false
  }

  private static func isDegraded(_ state: DisplayRuntimeState) -> Bool {
    if case .degraded = state { return true }
    return false
  }
}

private struct RestoreResult {
  var remaining: [DisplayRecoveryEntry]
  let hadOnlineFailure: Bool
}
