import AppKit
import CoreGraphics
import EmberCore
import Foundation

// MARK: - Snapshot (single coherent presentation source)

struct SolarPresentationData: Equatable {
  let eventKind: SolarEventKind?
  let eventDate: Date?
  let overrideExpiry: Date?
  let authorization: SolarLocationAuthorization
  let isRefreshing: Bool
  let errorMessage: String?
}

enum BacklightEngagement: Equatable {
  case disengaged
  case engaged
  case unavailable(String)
  case failed(String)
}

enum MenuBarClickResult: Equatable {
  case openedControls
  case toggledOn
  case toggledOff
  case ignoredBusy
}

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
  // 0.4.0 additions: observed truth + structured solar + engagement.
  let isObservedActive: Bool
  let verifiedDisplayCount: Int
  let failedDisplayCount: Int
  let attentionTitle: String?
  let attentionMessage: String?
  let backlightEngagement: BacklightEngagement
  let solarPresentation: SolarPresentationData

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
  private let clock: () -> Date

  private var settings: EmberSettings
  private var machine = DisplayStateMachine()
  private var recoveryEntries: [DisplayRecoveryEntry] = []
  private var controlledIdentities: Set<DisplayIdentity> = []
  private var verifiedIdentities: Set<DisplayIdentity> = []
  private var failedIdentities: [DisplayIdentity: String] = [:]
  private var unsupportedCount = 0
  private var backlightIdentity: DisplayIdentity?
  private var backlightEngagement: BacklightEngagement = .disengaged
  // Actor-owned timers (no nonisolated(unsafe)): all MainActor-isolated.
  private var guardTimer: Timer?
  private var healthTimer: Timer?
  private var pendingTransformTimer: Timer?
  private var settingsPersistTimer: Timer?
  private var pendingSettingsDirty = false
  private var consecutiveBacklightFailures = 0
  private var lastError: String?
  private var attentionOverride: AttentionState?
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
  // Generation-based topology reconciliation (invariant 9: stale op cannot win).
  private var topologyGeneration: UInt64 = 0
  private var reconcileTask: Task<Void, Never>?
  private var postVerifyTasks: [Task<Void, Never>] = []
  private var lastTopologySnapshot: DisplayTopologySnapshot?
  // Repeated-override detection: identity key -> reset timestamps (bounded 60s window).
  private var overrideHistory: [String: [Date]] = [:]
  private var isHandlingEvent = false

  private var appVersionString: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? AppVersion.marketing
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
    diagnostics: DiagnosticLog = DiagnosticLog(),
    clock: @escaping () -> Date = Date.init
  ) {
    self.gammaController = gammaController
    self.backlightController = backlightController
    self.launchAtLoginController = launchAtLoginController
    self.settingsStore = settingsStore
    self.recoveryJournal = recoveryJournal
    self.solarController = solarController
    self.diagnostics = diagnostics
    self.clock = clock
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
      // Prefer retaining scheduling preference with unavailable state; only
      // turn off on definitive denied/restricted with explanation.
      if message.lowercased().contains("denied") || message.lowercased().contains("restricted") {
        settings.sunScheduleEnabled = false
        settings.automationOverride = nil
        solarController.start(enabled: false)
        saveSettingsImmediately()
      }
      lastError = message
      attentionOverride = AttentionState(
        severity: .warning,
        title: "Location unavailable",
        message: message,
        recoveryActions: ["Open Location Settings"]
      )
      publishSnapshot()
    }
  }

  // MARK: - Lifecycle

  func start() {
    diagnostics.append("Project Ember \(appVersionString) started")
    diagnostics.append("System: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    recoverIfNeeded()
    probeCapabilities()

    let actualLoginState = launchAtLoginController.isEnabled
    if settings.launchAtLogin != actualLoginState {
      settings.launchAtLogin = actualLoginState
      saveSettingsImmediately()
    }

    if settings.sunScheduleEnabled {
      solarController.start(enabled: true)
    } else if settings.filterEnabled, machine.state == .off {
      performActivation()
    } else {
      publishSnapshot()
    }
    startHealthCheck()
  }

  func currentSnapshot() -> EmberSnapshot {
    if UserDefaults(suiteName: "app.projectember.visual-qa")?.bool(forKey: "forceActiveSnapshot") == true,
      CommandLine.arguments.contains("--snapshot-ui")
    {
      let count = max(compatibleDisplayCount, 1)
      return EmberSnapshot(
        settings: settings,
        runtimeState: .active,
        statusTitle: "Ember is on",
        statusDetail: "Active on \(count) \(count == 1 ? "display" : "displays").",
        displayAvailable: true,
        availableDisplayCount: max(availableDisplayCount, count),
        controlledDisplayCount: count,
        unsupportedDisplayCount: 0,
        pendingRestoreCount: 0,
        backlightAvailable: backlightCapability.brightnessControl,
        ambientLightControlAvailable: backlightCapability.ambientLightControl,
        solarStatusDetail: solarStatusDetail(),
        showLocationSettings: false,
        isBusy: false,
        isObservedActive: true,
        verifiedDisplayCount: count,
        failedDisplayCount: 0,
        attentionTitle: nil,
        attentionMessage: nil,
        backlightEngagement: backlightEngagement,
        solarPresentation: solarPresentationData()
      )
    }
    let presentation = buildPresentation()
    let busy =
      machine.state == .activating || machine.state == .reconciling
      || isRestoring(machine.state)
    return EmberSnapshot(
      settings: settings,
      runtimeState: machine.state,
      statusTitle: presentation.statusTitle,
      statusDetail: presentation.statusDetail,
      displayAvailable: compatibleDisplayCount > 0,
      availableDisplayCount: availableDisplayCount,
      controlledDisplayCount: verifiedIdentities.count,
      unsupportedDisplayCount: unsupportedDisplayCount,
      pendingRestoreCount: pendingRestoreCount,
      backlightAvailable: backlightCapability.brightnessControl,
      ambientLightControlAvailable: backlightCapability.ambientLightControl,
      solarStatusDetail: solarStatusDetail(),
      showLocationSettings: solarSnapshot.authorization == .denied
        || (solarSnapshot.authorization == .notDetermined
          && solarSnapshot.errorMessage != nil),
      isBusy: busy,
      isObservedActive: presentation.isObservedActive,
      verifiedDisplayCount: presentation.counts.verified,
      failedDisplayCount: presentation.counts.failed,
      attentionTitle: presentation.attention.severity == .none ? nil : presentation.attention.title,
      attentionMessage: presentation.attention.severity == .none
        ? nil : presentation.attention.message,
      backlightEngagement: backlightEngagement,
      solarPresentation: solarPresentationData()
    )
  }

  // MARK: - User intents

  func setFilterEnabled(_ enabled: Bool) {
    lastError = nil
    attentionOverride = nil
    if settings.sunScheduleEnabled, let event = solarSnapshot.schedule?.nextEvent {
      settings.automationOverride = AutomationOverride(
        filterEnabled: enabled,
        expiresAt: event.date
      )
      diagnostics.append(
        "Manual override set until \(event.kind.rawValue) at \(event.date.formatted())"
      )
    }
    applyFilterState(enabled, persistDisabledState: true)
  }

  /// Quick-toggle entry point for menu-bar primary click. Coalesces while busy.
  func handlePrimaryClick() -> MenuBarClickResult {
    if isBusyState() { return .ignoredBusy }
    switch settings.menuBarPrimaryAction {
    case .openControls:
      return .openedControls
    case .toggleEmber:
      let turningOn = !settings.filterEnabled || !currentSnapshot().isObservedActive
      // Reuse sun-override semantics.
      setFilterEnabled(turningOn)
      return turningOn ? .toggledOn : .toggledOff
    }
  }

  func setMenuBarPrimaryAction(_ action: MenuBarPrimaryAction) {
    settings.menuBarPrimaryAction = action
    saveSettingsDebounced()
    publishSnapshot()
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
    // Preference vs engagement: enabling stores preference even when the
    // target is currently unavailable; engagement is resolved during
    // activation/reconciliation. Only explicit user-off clears preference.
    if !enabled {
      settings.backlightLockEnabled = false
      backlightEngagement = .disengaged
      stopBacklightGuard()
      // Restore hardware if we had engaged, but preserve nothing else.
      if let identity = backlightIdentity,
        let target = try? gammaController.target(matching: identity),
        let index = recoveryEntries.firstIndex(where: { $0.identity.matches(identity) })
      {
        let hardware = recoveryEntries[index].hardware
        if hardware.hasValues {
          do {
            try backlightController.restore(hardware, on: target.displayID)
            recoveryEntries[index].hardware = .empty
            try? rewriteRecoveryRecord()
          } catch {
            diagnostics.append(
              "Backlight preference-off restore failed: \(error.localizedDescription)",
              level: "ERROR"
            )
          }
        }
      }
      saveSettingsImmediately()
      publishSnapshot()
      return
    }
    settings.backlightLockEnabled = true
    saveSettingsImmediately()
    if machine.state == .active {
      engageBacklightIfPossible()
    } else {
      backlightEngagement = .disengaged
    }
    publishSnapshot()
  }

  func setSunScheduleEnabled(_ enabled: Bool) {
    settings.sunScheduleEnabled = enabled
    settings.automationOverride = nil
    lastError = nil
    attentionOverride = nil

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
      saveSettingsImmediately()
      solarController.setEnabledByUser(true)
      diagnostics.append("Sun schedule enabled (Launch at login also enabled so transitions are not missed)")
    } else {
      solarController.setEnabledByUser(false)
      saveSettingsImmediately()
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
    saveSettingsImmediately()
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
    flushPendingSettings()
    cancelReconciliation(reason: "sleep")
    let shouldRestore: Bool = {
      switch machine.state {
      case .active, .activating, .reconciling: return true
      case .degraded: return true
      case .restoring: return false
      case .suspended, .off: return false
      }
    }()
    guard shouldRestore else { return }
    diagnostics.append("System sleep detected")
    resumeAfterWake = settings.filterEnabled
    // Sleep restores hardware but preserves Backlight Lock preference.
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

  // Legacy no-arg entry (tests + NS notification). Treated as end-of-transaction.
  func displayConfigurationChanged() {
    handleDisplayEvent(displayID: 0, flags: 0, isBegin: false)
  }

  /// Generation-based topology event. Preserves flags; begin marks reconciling
  /// without restoring; end settles by generation, never blanket-restores.
  func handleDisplayEvent(displayID: UInt32, flags: UInt32, isBegin: Bool) {
    topologyGeneration += 1
    let generation = topologyGeneration
    let event = DisplayReconfigurationEvent(
      displayID: displayID,
      flags: flags,
      isBeginTransaction: isBegin,
      generation: generation,
      timestamp: clock()
    )
    logDisplayEvent(event)
    cancelPostVerification(reason: "new generation \(generation)")
    reconcileTask?.cancel()

    if isBegin {
      // Mark reconciling; do not restore anything.
      if machine.state == .active || machine.state == .activating {
        _ = machine.transition(.displayChanged)
      }
      publishSnapshot()
      return
    }
    if machine.state == .active || machine.state == .activating || machine.state == .reconciling {
      _ = machine.transition(.displayChanged)
      publishSnapshot()
    }
    reconcileTask = Task { [weak self] in
      await self?.settleAndReconcile(generation: generation)
    }
    // Complementary main-thread settling signal is wired in AppDelegate via
    // NSApplication.didChangeScreenParametersNotification → same handler.
  }

  func shutdown() {
    NSObject.cancelPreviousPerformRequests(withTarget: self)
    cancelReconciliation(reason: "termination")
    flushPendingSettings()
    pendingTransformTimer?.invalidate()
    pendingTransformTimer = nil
    stopHealthCheck()
    guard machine.state == .active || machine.state == .activating
      || machine.state == .reconciling || isDegraded(machine.state) || recoveryJournal.exists
    else { return }
    diagnostics.append("Application termination requested")
    // Termination restores hardware but preserves Backlight Lock preference.
    restoreDisplay(intent: .terminate, persistDisabledState: false)
  }

  func resetDisplayNow() {
    cancelReconciliation(reason: "manual reset")
    pendingTransformTimer?.invalidate()
    pendingTransformTimer = nil
    stopBacklightGuard()
    let entries = loadJournalEntriesForMutation()
    var report = restoreEntriesVerified(entries)
    if report.hasFailure {
      gammaController.forceColorSyncRestore()
      diagnostics.append("ColorSync fallback applied after exact reset failure", level: "WARN")
      // Remove only entries actually matching saved baselines after fallback.
      var stillRemaining: [DisplayRecoveryEntry] = []
      for entry in report.remaining {
        if isBaselinePresent(entry) { continue }
        stillRemaining.append(entry)
      }
      report = RestoreReport(outcomes: report.outcomes, remaining: stillRemaining)
    }
    controlledIdentities.removeAll()
    verifiedIdentities.removeAll()
    failedIdentities.removeAll()
    settings.filterEnabled = false
    // Explicit emergency reset clears Backlight Lock preference (stated in UI).
    settings.backlightLockEnabled = false
    backlightEngagement = .disengaged
    backlightIdentity = nil
    recoveryEntries = report.remaining
    pendingRestoreCount = report.remaining.count
    saveSettingsImmediately()
    if report.remaining.isEmpty {
      try? recoveryJournal.clear()
      machine = DisplayStateMachine()
      lastError = nil
      attentionOverride = nil
      diagnostics.append("Manual display reset completed")
    } else {
      try? rewriteRecoveryRecord()
      let message = Self.pendingRestoreMessage(count: report.remaining.count)
      machine = DisplayStateMachine(state: .degraded(message))
      lastError = message
      attentionOverride = AttentionState(
        severity: .warning,
        title: "Needs attention",
        message: message,
        recoveryActions: ["Retry", "Reset"]
      )
      diagnostics.append(message, level: "WARN")
    }
    probeCapabilities()
    publishSnapshot()
  }

  func retryNow() {
    attentionOverride = nil
    lastError = nil
    overrideHistory.removeAll()
    if settings.filterEnabled {
      topologyGeneration += 1
      let generation = topologyGeneration
      reconcileTask?.cancel()
      reconcileTask = Task { [weak self] in
        await self?.settleAndReconcile(generation: generation)
      }
    } else {
      recoverPendingDisplaysIfPossible()
      probeCapabilities()
      publishSnapshot()
    }
  }

  func flushPendingSettings() {
    settingsPersistTimer?.invalidate()
    settingsPersistTimer = nil
    if pendingSettingsDirty {
      pendingSettingsDirty = false
      saveSettingsImmediately()
      if recoveryJournal.exists { try? rewriteRecoveryRecord() }
    }
  }

  func copyDiagnostics() -> String {
    diagnostics.formattedText()
  }

  /// Sanitized export: labels display identifiers without raw serials content.
  func exportDiagnostics() -> String {
    var lines = diagnostics.formattedText().components(separatedBy: "\n")
    lines = lines.map { sanitizeDiagnosticLine($0) }
    let header =
      "Project Ember \(appVersionString) diagnostics export (local-only, no user content)\n"
    return header + lines.joined(separator: "\n")
  }

  // MARK: - Activation / restore

  private func applyFilterState(
    _ enabled: Bool,
    persistDisabledState: Bool
  ) {
    if enabled {
      settings.filterEnabled = true
      saveSettingsImmediately()
      performActivation()
    } else if machine.state == .active || machine.state == .activating
      || machine.state == .reconciling || isDegraded(machine.state) || recoveryJournal.exists
    {
      restoreDisplay(intent: .disable, persistDisabledState: persistDisabledState)
    } else {
      settings.filterEnabled = false
      saveSettingsImmediately()
      publishSnapshot()
    }
  }

  private func performActivation() {
    guard settings.filterEnabled else { return }
    guard machine.state == .off || machine.state == .suspended || isDegraded(machine.state)
    else {
      if machine.state == .active { applyCurrentTransform() }
      return
    }
    _ = machine.transition(machine.state == .suspended ? .wakeRequested : .enableRequested)
    publishSnapshot()
    do {
      let priorEntries = loadJournalEntriesForMutation()
      // Attempt pending recovery that has become available before new capture.
      let pendingRecovery = restoreEntriesVerified(priorEntries)
      let pendingEntries = pendingRecovery.remaining
      // Pending entries that are now restored-verified are done; keep offline as pending.
      let targets = try gammaController.displayTargets()
      availableDisplayCount = targets.count
      compatibleDisplayCount = targets.filter(\.supportsGamma).count
      unsupportedDisplayCount = targets.count - compatibleDisplayCount
      let ambiguous = (try? gammaController.ambiguousIdentityKeys()) ?? []

      var freshEntries: [DisplayRecoveryEntry] = []
      for target in targets where target.supportsGamma {
        let key = DisplayTopologySnapshot.key(for: target.identity)
        if ambiguous.contains(key) {
          diagnostics.append(
            "Skipped ambiguous display \(target.displayID); identity matches multiple displays",
            level: "WARN"
          )
          continue
        }
        if pendingEntries.contains(where: { $0.identity.matches(target.identity) }) {
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
      guard !freshEntries.isEmpty, !pendingEntries.isEmpty || !freshEntries.isEmpty else {
        throw EmberError.noCompatibleDisplay
      }
      guard !freshEntries.isEmpty else { throw EmberError.noCompatibleDisplay }

      // Backlight: capture only on verified compatible built-in target, and only
      // when the current value was read successfully (stored in recovery entry).
      backlightIdentity = nil
      backlightCapability = .init(brightnessControl: false, ambientLightControl: false)
      if settings.backlightLockEnabled {
        for index in freshEntries.indices {
          let entry = freshEntries[index]
          guard entry.identity.isBuiltIn,
            let target = try gammaController.target(matching: entry.identity)
          else { continue }
          guard target.identity.isBuiltIn else { continue }
          let capability = backlightController.capability(for: target.displayID)
          guard capability.brightnessControl else { continue }
          do {
            freshEntries[index].hardware = try backlightController.captureBaseline(
              for: target.displayID
            )
            backlightIdentity = entry.identity
            backlightCapability = capability
            break
          } catch {
            diagnostics.append(
              "Backlight baseline capture failed; continuing with software dimming: \(error.localizedDescription)",
              level: "WARN"
            )
          }
        }
        if backlightIdentity == nil {
          backlightEngagement = .unavailable("Backlight Lock is unavailable on the current display.")
          diagnostics.append("Backlight Lock target unavailable; preference retained", level: "WARN")
        }
      }

      // Journal before mutation (invariant 1).
      recoveryEntries = pendingEntries + freshEntries
      pendingRestoreCount = pendingEntries.count
      try rewriteRecoveryRecord()
      diagnostics.append(
        "Recovery journal saved for \(recoveryEntries.count) displays before mutation"
      )

      // Apply each fresh entry from its immutable original baseline (invariant 3).
      var successful: Set<DisplayIdentity> = []
      var failed: [DisplayIdentity: String] = [:]
      for entry in freshEntries {
        do {
          try gammaController.apply(settings: settings, to: entry.display)
          successful.insert(entry.identity)
          verifiedIdentities.insert(entry.identity)
        } catch {
          // Preserve failed rollback entries (never filter to successful-only
          // when rollback cannot be proven).
          do {
            try gammaController.restoreVerified(entry.display)
          } catch {
            diagnostics.append(
              "Display \(entry.display.displayID) rollback failed; baseline retained: \(error.localizedDescription)",
              level: "ERROR"
            )
          }
          failed[entry.identity] = error.localizedDescription
          unsupportedDisplayCount += 1
          diagnostics.append(
            "Display \(entry.display.displayID) apply verification failed: \(error.localizedDescription)",
            level: "ERROR"
          )
        }
      }
      guard !successful.isEmpty else {
        // Keep every unsuccessful entry journaled.
        recoveryEntries = pendingEntries + freshEntries
        pendingRestoreCount = recoveryEntries.count
        try? rewriteRecoveryRecord()
        throw EmberError.noCompatibleDisplay
      }
      controlledIdentities = successful
      failedIdentities = failed
      // Retain failed-rollback entries: only drop nothing here; pending + fresh
      // all remain journaled until verified restoration.
      recoveryEntries = pendingEntries + freshEntries
      pendingRestoreCount = pendingEntries.count
      try rewriteRecoveryRecord()

      if settings.backlightLockEnabled, backlightIdentity != nil {
        engageBacklightIfPossible()
      }
      _ = machine.transition(.activationSucceeded)
      startBacklightGuard()
      startHealthCheck()
      resumeAfterWake = false
      if unsupportedDisplayCount == 0, failed.isEmpty { lastError = nil }
      schedulePostVerification(reason: "activation")
      diagnostics.append("Display transform active on \(successful.count) displays")
    } catch {
      diagnostics.append("Activation failed: \(error.localizedDescription)", level: "ERROR")
      stopBacklightGuard()
      let report = restoreEntriesVerified(recoveryEntries)
      recoveryEntries = report.remaining
      pendingRestoreCount = report.remaining.count
      controlledIdentities.removeAll()
      verifiedIdentities.removeAll()
      if report.remaining.isEmpty {
        try? recoveryJournal.clear()
      } else {
        try? rewriteRecoveryRecord()
      }
      _ = machine.transition(.activationFailed(error.localizedDescription))
      settings.filterEnabled = false
      // Preserve Backlight Lock preference across failed activation; only
      // engagement is reset.
      backlightEngagement = .disengaged
      saveSettingsImmediately()
      lastError = error.localizedDescription
      attentionOverride = AttentionState(
        severity: .error,
        title: "Needs attention",
        message: error.localizedDescription,
        recoveryActions: ["Retry", "Reset"]
      )
    }
    probeCapabilities(preserveUnsupportedCount: true)
    publishSnapshot()
  }

  private func restoreDisplay(intent: RestoreIntent, persistDisabledState: Bool) {
    pendingTransformTimer?.invalidate()
    pendingTransformTimer = nil
    flushPendingSettings()
    switch intent {
    case .disable: _ = machine.transition(.disableRequested)
    case .sleep: _ = machine.transition(.sleepRequested)
    case .terminate: _ = machine.transition(.terminationRequested)
    case .recovery: machine = DisplayStateMachine(state: .restoring(.recovery))
    }
    publishSnapshot()
    stopBacklightGuard()
    let entries = loadJournalEntriesForMutation()
    let report = restoreEntriesVerified(entries)
    controlledIdentities.removeAll()
    verifiedIdentities.removeAll()
    failedIdentities.removeAll()
    // Hardware state is restored by restoreEntriesVerified; engagement reset but
    // preference preserved (invariant: off/sleep/termination retain preference).
    backlightEngagement = .disengaged
    backlightIdentity = nil
    recoveryEntries = report.remaining
    pendingRestoreCount = report.remaining.count
    if persistDisabledState { settings.filterEnabled = false }
    saveSettingsImmediately()
    if report.remaining.isEmpty {
      _ = machine.transition(.restoreSucceeded)
      try? recoveryJournal.clear()
      lastError = nil
      attentionOverride = nil
      diagnostics.append("Saved state restored for every available display")
    } else {
      let message = Self.pendingRestoreMessage(count: report.remaining.count)
      _ = machine.transition(.restoreFailed(message))
      lastError = message
      // Pending-only disconnected uses calm copy via presentation model.
      attentionOverride = nil
      try? rewriteRecoveryRecord()
      diagnostics.append(message, level: "WARN")
    }
    probeCapabilities()
    publishSnapshot()
  }

  /// Verified restore per display. Keeps every unsuccessful entry journaled.
  private func restoreEntriesVerified(_ entries: [DisplayRecoveryEntry]) -> RestoreReport {
    var outcomes: [RestoreOutcome] = []
    var remaining: [DisplayRecoveryEntry] = []
    let ambiguous: Set<String> = (try? gammaController.ambiguousIdentityKeys()) ?? []
    for entry in entries {
      let key = DisplayTopologySnapshot.key(for: entry.identity)
      if ambiguous.contains(key) {
        outcomes.append(.identityAmbiguous(reason: "Multiple online displays match \(key)"))
        remaining.append(entry)
        diagnostics.append("Restore skipped: ambiguous identity \(key)", level: "WARN")
        continue
      }
      let target: DisplayTarget?
      do {
        target = try gammaController.target(matching: entry.identity)
      } catch {
        outcomes.append(.resolveFailed(message: error.localizedDescription))
        remaining.append(entry)
        diagnostics.append(
          "Display identity resolution failed during restore: \(error.localizedDescription)",
          level: "ERROR"
        )
        continue
      }
      guard let target else {
        outcomes.append(.displayOfflinePending(identity: entry.identity))
        remaining.append(entry)
        continue
      }
      do {
        try gammaController.restoreVerified(entry.display)
        if entry.hardware.hasValues {
          do {
            try backlightController.restore(entry.hardware, on: target.displayID)
          } catch {
            outcomes.append(.hardwareRestoreFailed(identity: entry.identity, message: error.localizedDescription))
            remaining.append(entry)
            diagnostics.append(
              "Hardware restore failed for display \(target.displayID): \(error.localizedDescription)",
              level: "ERROR"
            )
            continue
          }
        }
        outcomes.append(.restoredAndVerified(identity: entry.identity))
        diagnostics.append("Verified restore for display \(target.displayID)")
      } catch {
        remaining.append(entry)
        if error as? EmberError == EmberError.gammaVerificationFailed {
          let delta: Float
          do {
            let current = try gammaController.readTable(
              displayID: target.displayID, capacity: target.gammaCapacity)
            delta = current.maximumAbsoluteDifference(from: entry.display.gammaTable)
          } catch { delta = .infinity }
          outcomes.append(.gammaReadbackMismatch(identity: entry.identity, delta: delta))
        } else {
          outcomes.append(.gammaWriteFailed(identity: entry.identity, message: error.localizedDescription))
        }
        diagnostics.append(
          "Restore failed for display \(target.displayID): \(error.localizedDescription)",
          level: "ERROR"
        )
      }
    }
    return RestoreReport(outcomes: outcomes, remaining: remaining)
  }

  private func isBaselinePresent(_ entry: DisplayRecoveryEntry, tolerance: Float = 0.004) -> Bool {
    guard let target = try? gammaController.target(matching: entry.identity) else { return false }
    guard let current = try? gammaController.readTable(
      displayID: target.displayID, capacity: target.gammaCapacity)
    else { return false }
    return current.maximumAbsoluteDifference(from: entry.display.gammaTable) < tolerance
  }

  // MARK: - Generation-based reconciliation

  private func settleAndReconcile(generation: UInt64) async {
    // Sample immediately, then debounce 200-300ms; reconcile when two
    // consecutive identity snapshots match; bound at 2s.
    let deadline = clock().addingTimeInterval(2.0)
    var previous: DisplayTopologySnapshot?
    var current = sampleTopology(generation: generation)
    // Immediate sample logged; short debounce before second sample.
    try? await Task.sleep(nanoseconds: 250_000_000)
    guard generation == topologyGeneration, !Task.isCancelled else { return }
    var unstableWarning: String?
    while clock() < deadline {
      let next = sampleTopology(generation: generation)
      if next.matchesTopology(of: current)
        && (previous == nil || current.matchesTopology(of: previous!))
      {
        await reconcileSettledSnapshot(next, generation: generation, warning: unstableWarning)
        return
      }
      previous = current
      current = next
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard generation == topologyGeneration, !Task.isCancelled else { return }
    }
    unstableWarning = "Display topology did not stabilize within 2s; reconciled the latest safe snapshot."
    if let unstableWarning { diagnostics.append(unstableWarning, level: "WARN") }
    await reconcileSettledSnapshot(current, generation: generation, warning: unstableWarning)
  }

  private func sampleTopology(generation: UInt64) -> DisplayTopologySnapshot {
    let targets = (try? gammaController.displayTargets()) ?? []
    let entries = targets.map { t in
      DisplayTopologyEntry(
        identity: t.identity,
        displayID: t.displayID,
        isOnline: true,
        isActive: true,
        isMirrored: false,
        gammaCapacity: t.gammaCapacity,
        isBuiltIn: t.identity.isBuiltIn
      )
    }
    let snapshot = DisplayTopologySnapshot(
      generation: generation, capturedAt: clock(), entries: entries)
    lastTopologySnapshot = snapshot
    return snapshot
  }

  private func reconcileSettledSnapshot(
    _ snapshot: DisplayTopologySnapshot, generation: UInt64, warning: String?
  ) async {
    guard generation == topologyGeneration, !Task.isCancelled else { return }
    let desiredOn = settings.filterEnabled
    let ambiguous = (try? gammaController.ambiguousIdentityKeys()) ?? []
    // Map online topology keys for planner ambiguity (online duplicates).
    var keyCounts: [String: Int] = [:]
    for e in snapshot.entries { keyCounts[DisplayTopologySnapshot.key(for: e.identity), default: 0] += 1 }
    let onlineAmbiguous = Set(keyCounts.filter { $0.value > 1 }.map(\.key))
      .union(ambiguous)
    let plan = DisplayReconciler.plan(
      snapshot: snapshot,
      journaled: recoveryEntries,
      controlled: controlledIdentities,
      desiredOn: desiredOn,
      ambiguityKeys: onlineAmbiguous
    )
    logReconciliationPlan(plan, warning: warning)
    if !desiredOn {
      // Desired off: complete pending restores for reconnected displays.
      let report = restoreEntriesVerified(recoveryEntries)
      guard generation == topologyGeneration, !Task.isCancelled else { return }
      recoveryEntries = report.remaining
      pendingRestoreCount = report.remaining.count
      if report.remaining.isEmpty {
        try? recoveryJournal.clear()
        if machine.state == .reconciling { _ = machine.transition(.reconciliationSucceeded) }
        lastError = nil
      } else {
        try? rewriteRecoveryRecord()
      }
      probeCapabilities()
      publishSnapshot()
      return
    }
    // Desired ON: execute plan without blanket restore.
    if machine.state == .active || machine.state == .activating || machine.state == .reconciling {
      if machine.state != .reconciling { _ = machine.transition(.displayChanged) }
    }
    var newVerified = verifiedIdentities
    var newFailed = failedIdentities
    var addedEntries: [DisplayRecoveryEntry] = []
    var restoredAsPending: [DisplayRecoveryEntry] = []
    // Offline journaled → retain pending.
    let onlineKeys = Set(snapshot.entries.map { DisplayTopologySnapshot.key(for: $0.identity) })
    for entry in recoveryEntries {
      let key = DisplayTopologySnapshot.key(for: entry.identity)
      if onlineKeys.contains(key) == false {
        restoredAsPending.append(entry)
      }
    }
    for action in plan.actions {
      guard generation == topologyGeneration, !Task.isCancelled else { return }
      switch action {
      case .leaveVerified(let identity):
        newVerified.insert(identity)
        newFailed.removeValue(forKey: identity)
      case .reapplyFromBaseline(let identity):
        // Verify-then-maybe-reapply: leave untouched when still present.
        if let entry = recoveryEntries.first(where: { $0.identity.matches(identity) }) {
          if gammaController.isTransformInstalled(settings: settings, baseline: entry.display) {
            newVerified.insert(identity)
            newFailed.removeValue(forKey: identity)
            diagnostics.append("Verified display \(entry.display.displayID) still filtered; left untouched")
          } else {
            do {
              try gammaController.apply(settings: settings, to: entry.display)
              newVerified.insert(identity)
              newFailed.removeValue(forKey: identity)
              recordOverrideIfReset(identity: identity, repaired: true)
              diagnostics.append("Reapplied transform derived from saved baseline for display \(entry.display.displayID)")
            } catch {
              newVerified.remove(identity)
              newFailed[identity] = error.localizedDescription
              recordOverrideIfReset(identity: identity, repaired: false)
              diagnostics.append(
                "Reapply failed for display \(entry.display.displayID): \(error.localizedDescription)",
                level: "ERROR"
              )
            }
          }
        }
      case .journalThenApply(let identity):
        guard let target = try? gammaController.target(matching: identity),
          let online = snapshot.entries.first(where: { $0.identity.matches(identity) })
        else { continue }
        _ = target
        do {
          guard let live = (try? gammaController.displayTargets())?.first(where: {
            $0.identity.matches(identity)
          })
          else { continue }
          let baseline = try gammaController.captureBaseline(for: live)
          let newEntry = DisplayRecoveryEntry(identity: live.identity, display: baseline)
          // Append + durably save before any mutation (invariant 1).
          recoveryEntries.append(newEntry)
          try rewriteRecoveryRecord()
          do {
            try gammaController.apply(settings: settings, to: baseline)
            controlledIdentities.insert(live.identity)
            newVerified.insert(live.identity)
            addedEntries.append(newEntry)
            diagnostics.append("Journaled then applied new display \(live.displayID) before mutation")
          } catch {
            // Apply failed: restore captured baseline; retain entry if rollback unproven.
            do {
              try gammaController.restoreVerified(baseline)
              recoveryEntries.removeAll { $0.identity.matches(live.identity) }
              try? rewriteRecoveryRecord()
            } catch {
              diagnostics.append(
                "New-display rollback failed; baseline retained: \(error.localizedDescription)",
                level: "ERROR"
              )
            }
            newFailed[live.identity] = error.localizedDescription
          }
        } catch {
          diagnostics.append("New display capture failed: \(error.localizedDescription)", level: "WARN")
          _ = online
        }
      case .applyPendingBaseline(let identity):
        // Canonical saved baseline, never recapture (avoids app-induced flash).
        if let entry = recoveryEntries.first(where: { $0.identity.matches(identity) }) {
          do {
            try gammaController.apply(settings: settings, to: entry.display)
            controlledIdentities.insert(entry.identity)
            newVerified.insert(entry.identity)
            newFailed.removeValue(forKey: entry.identity)
            diagnostics.append("Applied pending baseline for reconnected display \(entry.display.displayID)")
          } catch {
            newFailed[entry.identity] = error.localizedDescription
            diagnostics.append(
              "Pending-display apply failed: \(error.localizedDescription)", level: "ERROR")
          }
        }
      case .restoreSavedBaseline(let identity):
        // Only on desired-off path; handled above. No-op here.
        _ = identity
      case .retainPending(let identity):
        _ = identity
      case .leaveUnsupported(let identity, let reason):
        diagnostics.append("Unsupported display left untouched: \(reason)", level: "INFO")
        _ = identity
      case .leaveAmbiguous(let reason):
        diagnostics.append("Ambiguous display left untouched: \(reason)", level: "WARN")
      }
    }
    guard generation == topologyGeneration, !Task.isCancelled else { return }
    verifiedIdentities = newVerified
    failedIdentities = newFailed
    // Update pending count from offline journaled.
    let journaledKeys = Set(recoveryEntries.map { DisplayTopologySnapshot.key(for: $0.identity) })
    _ = journaledKeys
    pendingRestoreCount = recoveryEntries.filter { entry in
      !onlineKeys.contains(DisplayTopologySnapshot.key(for: entry.identity))
    }.count
    _ = addedEntries
    _ = restoredAsPending
    // Backlight: retry engagement during reconciliation when preference set but
    // target was temporarily unavailable.
    if settings.backlightLockEnabled, backlightEngagement != .engaged {
      engageBacklightIfPossible()
    }
    probeCapabilities(preserveUnsupportedCount: false)
    // Recompute unsupported as online incompatible + failed-not-verified? Keep probe value
    // plus planner unsupported already counted via probe.
    if verifiedIdentities.isEmpty, desiredOn {
      let message = failedIdentities.values.first ?? "No verified display after reconciliation."
      _ = machine.transition(.reconciliationFailed(message))
      lastError = message
      attentionOverride = AttentionState(
        severity: .error, title: "Needs attention", message: message,
        recoveryActions: ["Retry", "Reset"])
    } else {
      if machine.state == .reconciling { _ = machine.transition(.reconciliationSucceeded) }
      if failedIdentities.isEmpty { lastError = nil; attentionOverride = nil }
      else {
        lastError = failedIdentities.values.joined(separator: " ")
        attentionOverride = AttentionState(
          severity: .warning, title: "Partially active",
          message: lastError ?? "", recoveryActions: ["Retry", "Reset"])
      }
      if let warning {
        diagnostics.append(warning, level: "WARN")
        if attentionOverride == nil {
          attentionOverride = AttentionState(
            severity: .warning, title: "Display topology unstable",
            message: warning, recoveryActions: ["Retry"])
        }
      }
    }
    publishSnapshot()
    if desiredOn, !verifiedIdentities.isEmpty {
      schedulePostVerification(reason: "reconciliation gen \(generation)")
    }
  }

  // MARK: - Verification (immediate + 0.5s + 2s + 30s health)

  private func schedulePostVerification(reason: String) {
    cancelPostVerification(reason: "reschedule \(reason)")
    let generation = topologyGeneration
    diagnostics.append("Scheduled post-reconciliation verification (\(reason)) gen \(generation)")
    for delay in [0.5, 2.0] {
      let task = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        await self?.runVerificationPass(generation: generation, kind: "post-\(delay)s")
      }
      postVerifyTasks.append(task)
    }
  }

  private func runVerificationPass(generation: UInt64, kind: String) async {
    guard generation == topologyGeneration, !Task.isCancelled else { return }
    guard settings.filterEnabled else { return }
    guard machine.state == .active || machine.state == .reconciling else { return }
    var repaired = 0
    for entry in recoveryEntries where controlledIdentities.contains(entry.identity)
      || verifiedIdentities.contains(entry.identity)
    {
      guard generation == topologyGeneration, !Task.isCancelled else { return }
      if gammaController.isTransformInstalled(settings: settings, baseline: entry.display) {
        continue
      }
      diagnostics.append(
        "Verification (\(kind)) detected OS reset on display \(entry.display.displayID); reapplying once",
        level: "WARN")
      do {
        try gammaController.apply(settings: settings, to: entry.display)
        repaired += 1
        recordOverrideIfReset(identity: entry.identity, repaired: true)
      } catch {
        recordOverrideIfReset(identity: entry.identity, repaired: false)
        diagnostics.append(
          "Verification reapply failed: \(error.localizedDescription)", level: "ERROR")
      }
    }
    guard generation == topologyGeneration, !Task.isCancelled else { return }
    if repaired > 0 {
      diagnostics.append("Verification (\(kind)) repaired \(repaired) display(s)")
      // Verify again after repair.
      let follow = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 500_000_000)
        await self?.runVerificationPass(generation: generation, kind: "follow-up")
      }
      postVerifyTasks.append(follow)
    }
    publishSnapshot()
  }

  private func recordOverrideIfReset(identity: DisplayIdentity, repaired: Bool) {
    let key = DisplayTopologySnapshot.key(for: identity)
    var history = overrideHistory[key] ?? []
    history.append(clock())
    // Keep 60s window.
    history = history.filter { clock().timeIntervalSince($0) < 60 }
    overrideHistory[key] = history
    if history.count >= 3 {
      let message =
        "Another display service is repeatedly replacing Ember’s color table on \(history.count) occasions in 60s. Ember paused automatic reapplication."
      lastError = message
      attentionOverride = AttentionState(
        severity: .error, title: "Needs attention", message: message,
        recoveryActions: ["Retry", "Reset"])
      diagnostics.append("Repeated external override on \(key): entering degraded attention state", level: "ERROR")
      _ = repaired
      publishSnapshot()
    }
  }

  private func startHealthCheck() {
    stopHealthCheck()
    let timer = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.runVerificationPass(
        generation: self?.topologyGeneration ?? 0, kind: "health-30s") }
    }
    timer.tolerance = 5.0
    RunLoop.main.add(timer, forMode: .common)
    healthTimer = timer
  }

  private func stopHealthCheck() {
    healthTimer?.invalidate()
    healthTimer = nil
  }

  private func cancelReconciliation(reason: String) {
    diagnostics.append("Cancelling reconciliation (\(reason)) gen \(topologyGeneration)")
    reconcileTask?.cancel()
    reconcileTask = nil
    cancelPostVerification(reason: reason)
  }

  private func cancelPostVerification(reason: String) {
    for t in postVerifyTasks { t.cancel() }
    postVerifyTasks.removeAll()
    _ = reason
  }

  // MARK: - Live transform / settings

  private func settingsDidChange(reapply: Bool) {
    // Debounce UserDefaults + journal rewrites ~150ms; flush on mouse-up,
    // popover close, sleep, termination, safety transitions.
    pendingSettingsDirty = true
    settingsPersistTimer?.invalidate()
    let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.flushPendingSettings() }
    }
    timer.tolerance = 0.05
    RunLoop.main.add(timer, forMode: .common)
    settingsPersistTimer = timer
    if reapply, machine.state == .active {
      _ = machine.transition(.settingsChanged)
      pendingTransformTimer?.invalidate()
      let coalesce = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
        Task { @MainActor in self?.flushPendingTransform() }
      }
      coalesce.tolerance = 0.02
      RunLoop.main.add(coalesce, forMode: .common)
      pendingTransformTimer = coalesce
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
        verifiedIdentities.insert(entry.identity)
      } catch {
        do { try gammaController.restoreVerified(entry.display) } catch {}
        failed.insert(entry.identity)
        verifiedIdentities.remove(entry.identity)
        diagnostics.append(
          "Live transform failed for display \(entry.display.displayID): \(error.localizedDescription)",
          level: "ERROR"
        )
      }
    }
    controlledIdentities.subtract(failed)
    for id in failed { failedIdentities[id] = "Live update failed" }
    unsupportedDisplayCount += failed.count
    if controlledIdentities.isEmpty, verifiedIdentities.isEmpty {
      machine = DisplayStateMachine(state: .degraded(EmberError.noCompatibleDisplay.localizedDescription))
      settings.filterEnabled = false
      saveSettingsImmediately()
      attentionOverride = AttentionState(
        severity: .error, title: "Needs attention",
        message: EmberError.noCompatibleDisplay.localizedDescription,
        recoveryActions: ["Retry", "Reset"])
    }
    publishSnapshot()
  }

  // MARK: - Recovery / journal safety

  private func loadJournalEntriesForMutation() -> [DisplayRecoveryEntry] {
    switch recoveryJournal.loadOutcome() {
    case .noJournal:
      if !recoveryEntries.isEmpty { return recoveryEntries }
      return []
    case .loaded(let record):
      // Merge in-memory pending that may be newer? Prefer journal as canonical
      // for baselines, but keep in-memory entries not yet journaled? In practice
      // recoveryEntries mirrors journal; return journal's displays.
      if recoveryEntries.isEmpty { return record.displays }
      // Union by identity key, journal wins for duplicates (canonical baseline).
      var byKey: [String: DisplayRecoveryEntry] = [:]
      for e in record.displays { byKey[DisplayTopologySnapshot.key(for: e.identity)] = e }
      for e in recoveryEntries {
        let k = DisplayTopologySnapshot.key(for: e.identity)
        if byKey[k] == nil { byKey[k] = e }
      }
      return Array(byKey.values)
    case .unsupportedFutureSchema(let version):
      handleJournalFailure(
        message: EmberError.journalUnsupportedSchema(version).localizedDescription)
      return recoveryEntries
    case .corrupt(let reason):
      // Quarantine, conservative ColorSync reset as last-resort safety, explicit attention.
      let url = recoveryJournal.quarantineCorruptJournal()
      gammaController.forceColorSyncRestore()
      let message =
        "Recovery journal is unreadable and was preserved\(url.map { " at \($0.lastPathComponent)" } ?? ""). Exact restoration cannot be claimed. Export diagnostics for support."
      diagnostics.append("Corrupt journal (\(reason)); quarantined, ColorSync reset attempted", level: "ERROR")
      lastError = message
      attentionOverride = AttentionState(
        severity: .error, title: "Needs attention", message: message,
        recoveryActions: ["Export Diagnostics", "Reset"])
      publishSnapshot()
      return recoveryEntries
    case .ioFailure(let message):
      handleJournalFailure(message: "Recovery journal could not be read: \(message)")
      return recoveryEntries
    }
  }

  private func handleJournalFailure(message: String) {
    lastError = message
    attentionOverride = AttentionState(
      severity: .error, title: "Needs attention", message: message,
      recoveryActions: ["Retry", "Reset"])
    diagnostics.append(message, level: "ERROR")
    publishSnapshot()
  }

  private func recoverIfNeeded() {
    guard recoveryJournal.exists else { return }
    diagnostics.append("Unclean previous exit detected; starting multi-display recovery", level: "WARN")
    machine = DisplayStateMachine(state: .restoring(.recovery))
    switch recoveryJournal.loadOutcome() {
    case .noJournal:
      machine = DisplayStateMachine()
      return
    case .loaded(let record):
      let report = restoreEntriesVerified(record.displays)
      recoveryEntries = report.remaining
      pendingRestoreCount = report.remaining.count
      settings.filterEnabled = false
      // Preserve Backlight Lock preference? Crash recovery stays off for safety;
      // keep preference so next manual on re-engages. Hardware already restored.
      saveSettingsImmediately()
      if report.remaining.isEmpty {
        try? recoveryJournal.clear()
        machine = DisplayStateMachine()
        lastError = nil
        attentionOverride = nil
        diagnostics.append("Crash recovery completed; Ember stayed off for safety")
      } else {
        try? rewriteRecoveryRecord()
        let message = Self.pendingRestoreMessage(count: report.remaining.count)
        machine = DisplayStateMachine(state: .degraded(message))
        lastError = message
        attentionOverride = nil
        diagnostics.append(message, level: "WARN")
      }
    case .unsupportedFutureSchema(let version):
      machine = DisplayStateMachine(
        state: .degraded(EmberError.journalUnsupportedSchema(version).localizedDescription))
      lastError = EmberError.journalUnsupportedSchema(version).localizedDescription
      attentionOverride = AttentionState(
        severity: .error, title: "Needs attention", message: lastError ?? "",
        recoveryActions: ["Export Diagnostics"])
      diagnostics.append(lastError ?? "Recovery failed", level: "ERROR")
    case .corrupt(let reason):
      let url = recoveryJournal.quarantineCorruptJournal()
      gammaController.forceColorSyncRestore()
      machine = DisplayStateMachine(state: .degraded(
        EmberError.journalCorrupt(reason).localizedDescription))
      lastError =
        "Previous display state could not be exactly restored (journal unreadable\(url.map { ", preserved at \($0.lastPathComponent)" } ?? "")). A system color reset was attempted."
      diagnostics.append(lastError ?? "Recovery failed", level: "ERROR")
      attentionOverride = AttentionState(
        severity: .error, title: "Needs attention",
        message: lastError ?? "", recoveryActions: ["Export Diagnostics", "Reset"])
    case .ioFailure(let message):
      machine = DisplayStateMachine(state: .degraded(message))
      lastError = "Previous display state could not be fully restored: \(message)"
      diagnostics.append(lastError ?? "Recovery failed", level: "ERROR")
    }
  }

  private func recoverPendingDisplaysIfPossible() {
    guard recoveryJournal.exists,
      machine.state != .active, machine.state != .activating,
      machine.state != .reconciling
    else { return }
    switch recoveryJournal.loadOutcome() {
    case .loaded(let record):
      let report = restoreEntriesVerified(record.displays)
      recoveryEntries = report.remaining
      pendingRestoreCount = report.remaining.count
      if report.remaining.isEmpty {
        try? recoveryJournal.clear()
        if !isDegraded(machine.state) { machine = DisplayStateMachine() }
        lastError = nil
        diagnostics.append("A reconnected display completed its pending recovery")
      } else {
        try? rewriteRecoveryRecord()
        let message = Self.pendingRestoreMessage(count: report.remaining.count)
        // Pending-only must not become a false alarm: keep calm copy.
        if !isDegraded(machine.state) { machine = DisplayStateMachine(state: .degraded(message)) }
        lastError = message
      }
    case .noJournal:
      return
    case .corrupt(let reason):
      _ = recoveryJournal.quarantineCorruptJournal()
      lastError = EmberError.journalCorrupt(reason).localizedDescription
      diagnostics.append("Pending recovery retry failed: \(lastError ?? "")", level: "ERROR")
    case .unsupportedFutureSchema(let version):
      lastError = EmberError.journalUnsupportedSchema(version).localizedDescription
      diagnostics.append("Pending recovery retry failed: \(lastError ?? "")", level: "ERROR")
    case .ioFailure(let message):
      lastError = message
      diagnostics.append("Pending recovery retry failed: \(message)", level: "ERROR")
    }
  }

  // MARK: - Capabilities / backlight

  private func probeCapabilities(preserveUnsupportedCount: Bool = false) {
    do {
      let targets = try gammaController.displayTargets()
      availableDisplayCount = targets.count
      compatibleDisplayCount = targets.filter(\.supportsGamma).count
      if !preserveUnsupportedCount {
        unsupportedDisplayCount = targets.count - compatibleDisplayCount
      }
      // Select Backlight Lock target only when identity.isBuiltIn == true.
      backlightIdentity = nil
      backlightCapability = .init(brightnessControl: false, ambientLightControl: false)
      for target in targets where target.supportsGamma && target.identity.isBuiltIn {
        let capability = backlightController.capability(for: target.displayID)
        if capability.brightnessControl {
          backlightIdentity = target.identity
          backlightCapability = capability
          break
        }
      }
      diagnostics.append(
        "Capabilities: online=\(availableDisplayCount), gamma=\(compatibleDisplayCount), backlight=\(backlightCapability.brightnessControl) gen=\(topologyGeneration)"
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

  private func engageBacklightIfPossible() {
    guard settings.backlightLockEnabled else {
      backlightEngagement = .disengaged
      return
    }
    guard let identity = backlightIdentity ?? recoveryEntries.first(where: {
      $0.identity.isBuiltIn && $0.hardware.hasValues
    })?.identity,
      identity.isBuiltIn,
      let target = try? gammaController.target(matching: identity)
    else {
      backlightEngagement = .unavailable("Backlight Lock target is temporarily disconnected; preference retained.")
      diagnostics.append("Backlight engagement deferred: target unavailable, preference retained")
      return
    }
    guard target.identity.isBuiltIn else {
      backlightEngagement = .unavailable("Backlight Lock is available on the built-in display only.")
      return
    }
    do {
      // If hardware baseline was not captured (getter failed earlier), capture now;
      // if it still fails, leave automatic brightness untouched (reduced capability).
      if let index = recoveryEntries.firstIndex(where: { $0.identity.matches(identity) }),
        !recoveryEntries[index].hardware.hasValues
      {
        do {
          recoveryEntries[index].hardware = try backlightController.captureBaseline(
            for: target.displayID)
          try? rewriteRecoveryRecord()
        } catch {
          diagnostics.append(
            "Backlight capture failed; continuing with software dimming: \(error.localizedDescription)",
            level: "WARN")
        }
      }
      try backlightController.engage(on: target.displayID)
      backlightEngagement = .engaged
      backlightIdentity = identity
      diagnostics.append("Backlight Lock engaged on the verified built-in display")
    } catch {
      diagnostics.append("Backlight engage failed: \(error.localizedDescription)", level: "WARN")
      backlightEngagement = .failed(error.localizedDescription)
    }
  }

  private func rewriteRecoveryRecord() throws {
    guard !recoveryEntries.isEmpty else {
      try recoveryJournal.clear()
      return
    }
    let record = RecoveryRecord(
      appVersion: appVersionString,
      displays: recoveryEntries,
      intendedSettings: settings
    )
    try recoveryJournal.save(record)
  }

  private func startBacklightGuard() {
    stopBacklightGuard()
    consecutiveBacklightFailures = 0
    guard settings.backlightLockEnabled else { return }
    // Read-before-write guard: poll modestly, write only on drift, with tolerance.
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

  private func maintainBacklightLock() {
    guard settings.backlightLockEnabled,
      machine.state == .active,
      let identity = backlightIdentity,
      identity.isBuiltIn,
      let target = try? gammaController.target(matching: identity),
      target.identity.isBuiltIn
    else {
      // Temporarily unavailable: preserve preference, mark unavailable, retry
      // during topology/wake reconciliation rather than stopping forever.
      if settings.backlightLockEnabled, backlightEngagement == .engaged {
        backlightEngagement = .unavailable("Backlight target unavailable; will retry.")
      }
      return
    }
    // Read before writing (invariant: no unconditional hardware writes).
    if !backlightController.needsEngagement(on: target.displayID) {
      consecutiveBacklightFailures = 0
      if backlightEngagement != .engaged { backlightEngagement = .engaged }
      return
    }
    do {
      try backlightController.engage(on: target.displayID)
      consecutiveBacklightFailures = 0
      backlightEngagement = .engaged
      diagnostics.append("Backlight guard corrected drift with one bounded write + verification")
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
        // Preserve preference; mark failed engagement truthfully.
        backlightEngagement = .failed("Backlight Lock stopped after three write failures.")
        try? rewriteRecoveryRecord()
        lastError = "Backlight Lock stopped after three system-level write failures."
        publishSnapshot()
      }
    }
  }

  // MARK: - Solar

  private func handleSolarSchedule(_ schedule: SolarSchedule) {
    guard settings.sunScheduleEnabled else { return }
    let now = clock()
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
      // Sunrise/day restores hardware but preserves Backlight Lock preference.
      applyFilterState(desiredState, persistDisabledState: true)
    } else {
      saveSettingsImmediately()
      publishSnapshot()
    }
  }

  private func solarPresentationData() -> SolarPresentationData {
    SolarPresentationData(
      eventKind: solarSnapshot.schedule?.nextEvent?.kind,
      eventDate: solarSnapshot.schedule?.nextEvent?.date,
      overrideExpiry: settings.automationOverride?.expiresAt,
      authorization: solarSnapshot.authorization,
      isRefreshing: solarSnapshot.isRefreshing,
      errorMessage: solarSnapshot.errorMessage
    )
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
      return "Sun schedule needs Launch at login so transitions are not missed while Ember is closed."
    }
    if let message = solarSnapshot.errorMessage { return message }
    if solarSnapshot.isRefreshing, solarSnapshot.schedule == nil {
      return "Getting an approximate location…"
    }
    if let override = settings.automationOverride,
      override.expiresAt > clock(),
      let event = solarSnapshot.schedule?.nextEvent
    {
      return "Manual override until \(Self.eventDescription(event, includePrefix: false))."
    }
    if let event = solarSnapshot.schedule?.nextEvent {
      return "Next: \(Self.eventDescription(event, includePrefix: true))."
    }
    return "Waiting for the next local solar transition."
  }

  // MARK: - Wake / timers

  @objc private func resumeAfterSystemWake() {
    probeCapabilities()
    if settings.sunScheduleEnabled {
      solarController.refresh(forceLocation: false)
    } else if resumeAfterWake, settings.filterEnabled {
      performActivation()
    } else if !settings.filterEnabled {
      recoverPendingDisplaysIfPossible()
      publishSnapshot()
    }
    resumeAfterWake = false
  }

  // MARK: - Presentation

  private func buildPresentation() -> EmberPresentation {
    let verifiedKeys = Set(verifiedIdentities.map { DisplayTopologySnapshot.key(for: $0) })
    let failedMessages = Array(failedIdentities.values)
    let onlineIntended = max(compatibleDisplayCount, verifiedIdentities.count)
    if let override = attentionOverride, override.severity != .none {
      return EmberPresenter.make(
        desiredOn: settings.filterEnabled,
        operation: operationState(),
        verified: verifiedKeys,
        unsupported: unsupportedDisplayCount,
        pending: pendingRestoreCount,
        failed: failedMessages,
        onlineIntended: onlineIntended,
        attentionOverride: override
      )
    }
    // Pending-only disconnected: calm but truthful (no false alarm).
    if pendingRestoreCount > 0, verifiedKeys.isEmpty, failedMessages.isEmpty {
      if settings.filterEnabled {
        return EmberPresenter.make(
          desiredOn: true,
          operation: operationState(),
          verified: verifiedKeys,
          unsupported: unsupportedDisplayCount,
          pending: pendingRestoreCount,
          failed: [],
          onlineIntended: onlineIntended
        )
      }
      let calm = AttentionState(
        severity: .info,
        title: "Ember is off",
        message: Self.pendingRestoreMessage(count: pendingRestoreCount),
        recoveryActions: [])
      return EmberPresentation(
        desiredFilterEnabled: false,
        operationState: operationState(),
        isObservedActive: false,
        counts: DisplayCountSummary(
          verified: 0, unsupported: unsupportedDisplayCount,
          pending: pendingRestoreCount, failed: 0),
        attention: calm,
        statusTitle: "Ember is off",
        statusDetail: "Your displays look normal.")
    }
    return EmberPresenter.make(
      desiredOn: settings.filterEnabled,
      operation: operationState(),
      verified: verifiedKeys,
      unsupported: unsupportedDisplayCount,
      pending: pendingRestoreCount,
      failed: failedMessages,
      onlineIntended: onlineIntended
    )
  }

  private func operationState() -> EmberOperationState {
    switch machine.state {
    case .off: return .off
    case .activating: return .activating
    case .active: return .active
    case .reconciling: return .reconciling
    case .restoring: return .restoring
    case .suspended: return .suspended
    case .degraded: return .degraded
    }
  }

  private func isBusyState() -> Bool {
    machine.state == .activating || machine.state == .reconciling || isRestoring(machine.state)
  }

  private func saveSettingsImmediately() {
    do {
      try settingsStore.save(settings)
    } catch {
      lastError = "Settings could not be saved: \(error.localizedDescription)"
      diagnostics.append(lastError ?? "Settings save failed", level: "ERROR")
    }
  }

  private func saveSettingsDebounced() {
    pendingSettingsDirty = true
    settingsPersistTimer?.invalidate()
    let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.flushPendingSettings() }
    }
    timer.tolerance = 0.05
    RunLoop.main.add(timer, forMode: .common)
    settingsPersistTimer = timer
  }

  private func publishSnapshot() {
    onSnapshot?(currentSnapshot())
  }

  // MARK: - Diagnostics helpers

  private func logDisplayEvent(_ event: DisplayReconfigurationEvent) {
    let flags = event.flagNames.joined(separator: ",")
    diagnostics.append(
      "Display event gen=\(event.generation) id=\(event.displayID) begin=\(event.isBeginTransaction) flags=[\(flags)]"
    )
  }

  private func logReconciliationPlan(_ plan: DisplayReconciliationPlan, warning: String?) {
    let summary = plan.actions.map { String(describing: $0) }.joined(separator: "; ")
    diagnostics.append("Reconciliation gen=\(plan.generation) actions=[\(summary)]")
    diagnostics.append(
      "Topology snapshot identities=[\(lastTopologySnapshot?.entries.map { DisplayTopologySnapshot.key(for: $0.identity) }.joined(separator: ",") ?? "")]"
    )
    if let warning { diagnostics.append(warning, level: "WARN") }
    diagnostics.append(
      "Journal outcome: entries=\(recoveryEntries.count) pending=\(pendingRestoreCount) verified=\(verifiedIdentities.count)"
    )
  }

  private func sanitizeDiagnosticLine(_ line: String) -> String {
    // Label display identifiers/serials without exposing raw values verbatim.
    // Keep the line structure; replace long hex UUIDs with a placeholder.
    var out = line
    let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    if let regex = try? NSRegularExpression(pattern: pattern) {
      out = regex.stringByReplacingMatches(
        in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<display-uuid>")
    }
    return out
  }

  // MARK: - Static helpers

  static func defaultRecoveryURL() -> URL {
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

  private func isRestoring(_ state: DisplayRuntimeState) -> Bool { Self.isRestoring(state) }
  private func isDegraded(_ state: DisplayRuntimeState) -> Bool { Self.isDegraded(state) }
}
