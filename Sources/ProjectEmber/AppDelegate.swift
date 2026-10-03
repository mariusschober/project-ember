import AppKit
import CoreGraphics
import EmberCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let coordinator: DisplayCoordinator
  private var statusItem: NSStatusItem!
  private lazy var statusMenu = NSMenu()
  private let popover = NSPopover()
  private var panelController: ControlPanelViewController!
  private var diagnosticsController: DiagnosticsWindowController!
  private var workspaceObservers: [NSObjectProtocol] = []
  private var systemObservers: [NSObjectProtocol] = []
  private var displayObserver: DisplayReconfigurationObserver?
  #if DEBUG
  /// Visual-QA window. DEBUG only: `--show-panel`/`--snapshot-ui` are ignored
  /// outright by a release build (they exist to render the real UI for review).
  private var qaWindow: NSWindow?
  #endif
  private var visualQAMode = false
  /// Last status-item presentation; the health tick re-renders the same state
  /// every 30 s and must not touch the status item for an unchanged snapshot.
  private var lastStatusPresentation: StatusItemPresentation?

  /// First-launch popover flag; also the App Store reviewer's first ten seconds.
  private static let didPresentFirstRunKey = "app.projectember.didPresentFirstRunHint"

  #if DEBUG
  /// True only when a QA flag was passed. QA mode gets an isolated journal (see
  /// `qaRecoveryJournal`) and never activates the app.
  private static var isVisualQARequested: Bool {
    CommandLine.arguments.contains("--show-panel")
      || CommandLine.arguments.contains("--snapshot-ui")
  }

  /// QA runs must never touch the user's real recovery journal: `--snapshot-ui`
  /// next to an installed instance would otherwise race it (audit m11).
  private static var qaRecoveryJournal: RecoveryJournal {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("project-ember-visual-qa", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return RecoveryJournal(
      fileURL: base.appendingPathComponent("display-recovery-v1.json"))
  }
  #endif

  /// The QA flags compile to `false` in release builds: the QA window, its
  /// isolated journal and the snapshot path exist only in DEBUG (audit m11).
  private static var visualQARequested: Bool {
    #if DEBUG
    return isVisualQARequested
    #else
    return false
    #endif
  }

  override init() {
    #if DEBUG
    if Self.isVisualQARequested, let defaults = UserDefaults(suiteName: "app.projectember.visual-qa") {
      coordinator = DisplayCoordinator(
        settingsStore: SettingsStore(defaults: defaults),
        recoveryJournal: Self.qaRecoveryJournal,
        solarController: SolarScheduleController(
          locationStore: SolarLocationStore(defaults: defaults)
        )
      )
    } else {
      coordinator = DisplayCoordinator()
    }
    #else
    coordinator = DisplayCoordinator()
    #endif
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    visualQAMode = Self.visualQARequested
    NSApp.setActivationPolicy(visualQAMode ? .regular : .accessory)
    setupDiagnostics()
    setupPanel()
    setupStatusItem()
    setupLifecycleObservers()

    coordinator.onSnapshot = { [weak self] snapshot in
      guard let self else { return }
      // PERF-F3: a health tick must not rebuild an invisible panel. The popover
      // renders when it is shown (showPopover), so an off-screen snapshot is
      // only ever used for the status item.
      if self.isPanelVisible { self.panelController.render(snapshot) }
      self.renderStatusItem(snapshot)
    }
    coordinator.start()
    #if DEBUG
    if visualQAMode {
      panelController.render(coordinator.currentSnapshot())
      qaWindow?.setContentSize(panelController.preferredContentSize)
    }
    #endif
    renderStatusItem(coordinator.currentSnapshot())

    #if DEBUG
    if visualQAMode {
      DispatchQueue.main.async { [weak self] in
        // No NSApp.activate: a QA render must never steal focus from whatever
        // the user is doing (audit m11).
        self?.qaWindow?.center()
        self?.qaWindow?.makeKeyAndOrderFront(nil)
        self?.captureSnapshotIfRequested()
      }
      return
    }
    #endif

    // First run: open the panel once and explain what Ember does and how to
    // turn it on. Once per install, then never again.
    DispatchQueue.main.async { [weak self] in
      self?.presentFirstRunIfNeeded()
    }
  }

  private var isPanelVisible: Bool {
    if popover.isShown { return true }
    #if DEBUG
    return visualQAMode && qaWindow?.isVisible == true
    #else
    return false
    #endif
  }

  private func presentFirstRunIfNeeded() {
    guard !visualQAMode else { return }
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.didPresentFirstRunKey) else { return }
    defaults.set(true, forKey: Self.didPresentFirstRunKey)
    panelController.setFirstRunHint(true)
    showPopover()
  }

  func applicationWillTerminate(_ notification: Notification) {
    coordinator.shutdown()
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.forEach(center.removeObserver)
    let notificationCenter = NotificationCenter.default
    systemObservers.forEach(notificationCenter.removeObserver)
  }

  private func setupDiagnostics() {
    diagnosticsController = DiagnosticsWindowController(
      textProvider: { [weak coordinator] in
        coordinator?.diagnostics.formattedText() ?? "No diagnostics available."
      },
      exportProvider: { [weak coordinator] in
        coordinator?.exportDiagnostics() ?? "No diagnostics available."
      },
      resetHandler: { [weak coordinator] in
        coordinator?.resetDisplayNow()
      },
      retryHandler: { [weak coordinator] in
        coordinator?.retryNow()
      }
    )
  }

  private func setupPanel() {
    panelController = ControlPanelViewController(
      coordinator: coordinator,
      showDiagnostics: { [weak self] in
        self?.popover.performClose(nil)
        self?.diagnosticsController.present()
      }
    )
    #if DEBUG
    if visualQAMode {
      let window = NSWindow(
        contentRect: NSRect(
          origin: .zero,
          size: panelController.preferredContentSize
        ),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.title = "Project Ember · Visual QA"
      window.appearance = NSAppearance(named: .darkAqua)
      window.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1.0)
      window.contentViewController = panelController
      window.isReleasedWhenClosed = false
      qaWindow = window
      return
    }
    #endif
    popover.behavior = .transient
    popover.animates = true
    popover.appearance = NSAppearance(named: .darkAqua)
    popover.contentSize = panelController.preferredContentSize
    popover.contentViewController = panelController
  }

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = statusItem.button else { return }
    button.target = self
    button.action = #selector(statusItemClicked)
    // Receive left and right mouse-up separately for quick-toggle behavior.
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    button.imagePosition = .imageOnly
    button.toolTip = "Project Ember"
    button.setAccessibilityLabel("Project Ember display controls")
    button.setAccessibilityHelp(
      "Left click follows the Menu bar click setting. Right click or Control-click opens the controls. Option-click opens a menu with controls, diagnostics, about and quit."
    )
    buildStatusMenu()
  }

  /// Alternate-action menu, shown on Option-click. Kept because this app has no
  /// Dock icon and no app menu, so a path to Quit that does not depend on the
  /// popover is worth having — but it must not shadow the primary gesture, which
  /// is why 0.5.0's right-click mapping was reverted.
  private func buildStatusMenu() {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let open = NSMenuItem(
      title: "Open Controls", action: #selector(menuOpenControls), keyEquivalent: "")
    open.target = self
    menu.addItem(open)

    menu.addItem(.separator())

    let diagnostics = NSMenuItem(
      title: "Diagnostics…", action: #selector(menuOpenDiagnostics), keyEquivalent: "")
    diagnostics.target = self
    menu.addItem(diagnostics)

    let about = NSMenuItem(
      title: "About Project Ember", action: #selector(menuOpenAbout), keyEquivalent: "")
    about.target = self
    menu.addItem(about)

    menu.addItem(.separator())

    let quit = NSMenuItem(
      title: "Quit Project Ember", action: #selector(menuQuit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)

    statusMenu = menu
  }

  private func showStatusMenu() {
    guard let button = statusItem.button else { return }
    statusMenu.popUp(
      positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
  }

  private func setupLifecycleObservers() {
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(
      center.addObserver(
        forName: NSWorkspace.willSleepNotification,
        object: nil,
        queue: .main
      ) { [weak coordinator] _ in
        MainActor.assumeIsolated { coordinator?.willSleep() }
      })
    workspaceObservers.append(
      center.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
      ) { [weak coordinator] _ in
        MainActor.assumeIsolated { coordinator?.didWake() }
      })

    let notificationCenter = NotificationCenter.default
    systemObservers.append(
      notificationCenter.addObserver(
        forName: .NSSystemClockDidChange,
        object: nil,
        queue: .main
      ) { [weak coordinator] _ in
        MainActor.assumeIsolated { coordinator?.systemTimeChanged() }
      }
    )
    systemObservers.append(
      notificationCenter.addObserver(
        forName: .NSSystemTimeZoneDidChange,
        object: nil,
        queue: .main
      ) { [weak coordinator] _ in
        MainActor.assumeIsolated { coordinator?.systemTimeChanged() }
      }
    )
    // Complementary main-thread settling signal; CoreGraphics flags remain the
    // source of detailed topology information.
    systemObservers.append(
      notificationCenter.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil,
        queue: .main
      ) { [weak coordinator] _ in
        MainActor.assumeIsolated { coordinator?.displayConfigurationChanged() }
      }
    )

    displayObserver = DisplayReconfigurationObserver { [weak coordinator] event in
      coordinator?.handleDisplayEvent(
        displayID: event.displayID, flags: event.flags, isBegin: event.isBeginTransaction)
    }
  }

  // Cached status images: avoid redrawing on every snapshot/slider event.
  private lazy var cachedInactiveImage: NSImage = EmberDotIcon.inactiveImage()
  private lazy var cachedActiveImage: NSImage = EmberDotIcon.activeImage()
  private lazy var cachedDegradedImage: NSImage = EmberDotIcon.degradedImage()

  /// What the status item currently shows. Comparing this before touching the
  /// button keeps the 30 s health tick (and every slider event) free when the
  /// visible state has not changed.
  private struct StatusItemPresentation: Equatable {
    let description: String
    let value: String
  }

  private func renderStatusItem(_ snapshot: EmberSnapshot) {
    guard let button = statusItem.button else { return }
    let image: NSImage
    let description: String
    let value: String
    // Observed truth drives the UI: active only when verified.
    let isActive = snapshot.isObservedActive && snapshot.runtimeState == .active
    let needsAttention = snapshot.attentionTitle != nil
      && snapshot.statusTitle == "Needs attention"
    switch snapshot.runtimeState {
    case .active where isActive:
      image = cachedActiveImage
      description = "Project Ember active"
      value = "Active on \(snapshot.verifiedDisplayCount) displays"
    case .degraded where needsAttention:
      image = cachedDegradedImage
      description = "Project Ember needs attention"
      value = snapshot.attentionMessage ?? "Needs attention"
    case .activating, .restoring, .reconciling:
      image = cachedInactiveImage
      description = "Project Ember working"
      value = snapshot.statusDetail
    default:
      if needsAttention {
        image = cachedDegradedImage
        description = "Project Ember needs attention"
        value = snapshot.attentionMessage ?? "Needs attention"
      } else if isActive {
        image = cachedActiveImage
        description = "Project Ember active"
        value = "Active"
      } else {
        image = cachedInactiveImage
        description = snapshot.statusTitle == "Paused for sleep"
          ? "Project Ember paused for sleep" : "Project Ember ready"
        value = snapshot.statusDetail
      }
    }
    let presentation = StatusItemPresentation(description: description, value: value)
    guard presentation != lastStatusPresentation else { return }
    lastStatusPresentation = presentation
    button.image = image
    // Never force isTemplate: the inactive and attention dots are template
    // images so the system tints them for a light or dark menu bar, which is
    // exactly the 1.80:1 failure the audit measured in Light Mode (M5).
    button.image?.size = NSSize(width: 16, height: 16)
    button.toolTip = description
    button.setAccessibilityLabel(description)
    button.setAccessibilityValue(value)
    button.setAccessibilityHelp(
      "Left click: \(snapshot.settings.menuBarPrimaryAction == .toggleEmber ? "toggle Ember" : "open controls"). Right click or Control-click opens the controls. Option-click opens a menu with controls, diagnostics, about and quit."
    )
  }

  @objc private func statusItemClicked() {
    guard let event = NSApp.currentEvent else {
      togglePopover()
      return
    }
    // Gesture routing lives in EmberCore so the documented behaviour has one
    // definition and a test (MenuBarRouting.statusClick).
    let route = MenuBarRouting.statusClick(
      isRightClick: event.type == .rightMouseUp,
      isControlClick: event.type == .leftMouseUp && event.modifierFlags.contains(.control),
      isOptionClick: event.type == .leftMouseUp && event.modifierFlags.contains(.option)
    )
    switch route {
    case .openControls:
      // Right-click, two-finger click and Control-click open the controls, as
      // 0.4.0 behaved and as the README documents. 0.5.0 briefly put the menu
      // here, which shadowed the gesture users had learned.
      openControls()
      return
    case .showAlternateMenu:
      // Option-click is the standard macOS alternate action: the same menu,
      // kept as the safety net for quitting without the popover.
      showStatusMenu()
      return
    case .primaryAction:
      break
    }
    // Left click routes according to preference.
    let result = coordinator.handlePrimaryClick()
    switch result {
    case .openedControls:
      togglePopover()
    case .toggledOn, .toggledOff:
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
      // Update icon immediately to working; verification publishes final state.
      renderStatusItem(coordinator.currentSnapshot())
    case .ignoredBusy:
      break
    }
  }

  // MARK: - Status menu actions

  @objc private func menuOpenControls() {
    openControls()
  }

  @objc private func menuOpenDiagnostics() {
    if popover.isShown { popover.performClose(nil) }
    diagnosticsController.present()
  }

  @objc private func menuQuit() {
    NSApp.terminate(nil)
  }

  /// About: the product sentence, the privacy statement and the license, with
  /// the version read from the bundle. The first-run popover explains what
  /// Ember does; this is where the reviewer finds the ownership terms.
  @objc private func menuOpenAbout() {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    let credits = NSMutableAttributedString(
      string:
        """
        Warms and dims your display after dark. Ember reports what it can verify: it does not measure PWM and makes no medical claims.

        Privacy: no accounts, no analytics, no network access. Settings, approximate location and the display recovery journal stay on this Mac.

        © 2026 Marius Schober. All rights reserved.
        """,
      attributes: [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.labelColor,
      ])
    let options: [NSApplication.AboutPanelOptionKey: Any] = [
      .applicationName: "Project Ember",
      .applicationVersion: version ?? AppVersion.marketing,
      .version: build ?? "",
      .credits: credits,
    ]
    NSApp.orderFrontStandardAboutPanel(options: options)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func openControls() {
    #if DEBUG
    if visualQAMode {
      qaWindow?.makeKeyAndOrderFront(nil)
      return
    }
    #endif
    if !popover.isShown { showPopover() }
  }

  @objc private func togglePopover() {
    #if DEBUG
    if visualQAMode {
      qaWindow?.makeKeyAndOrderFront(nil)
      return
    }
    #endif
    if popover.isShown {
      popover.performClose(nil)
    } else {
      // Fallback path (e.g., keyboard activation): respect primary action.
      let result = coordinator.handlePrimaryClick()
      if result == .openedControls || result == .ignoredBusy {
        if result == .openedControls { showPopover() }
      } else {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        renderStatusItem(coordinator.currentSnapshot())
      }
    }
  }

  private func showPopover() {
    guard let button = statusItem.button else { return }
    // Render first: the render measures the content and updates
    // preferredContentSize, which is the size the popover must open at.
    panelController.render(coordinator.currentSnapshot())
    popover.contentSize = panelController.preferredContentSize
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    if let win = popover.contentViewController?.view.window {
      win.appearance = NSAppearance(named: .darkAqua)
    }
  }

  #if DEBUG
  private func captureSnapshotIfRequested() {
    guard let argumentIndex = CommandLine.arguments.firstIndex(of: "--snapshot-ui"),
      CommandLine.arguments.indices.contains(argumentIndex + 1)
    else {
      return
    }
    let destination = URL(fileURLWithPath: CommandLine.arguments[argumentIndex + 1])
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, let view = qaWindow?.contentView else {
        NSApp.terminate(nil)
        return
      }
      qaWindow?.displayIfNeeded()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        diagnosticsFailure("Could not allocate a view snapshot.")
        NSApp.terminate(nil)
        return
      }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      do {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
          throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: destination, options: [.atomic])
      } catch {
        diagnosticsFailure("UI snapshot failed: \(error.localizedDescription)")
      }
      NSApp.terminate(nil)
    }
  }
  #endif

  private func diagnosticsFailure(_ message: String) {
    coordinator.diagnostics.append(message, level: "ERROR")
    if let data = "\(message)\n".data(using: .utf8) {
      FileHandle.standardError.write(data)
    }
  }
}

private func emberDisplayReconfigurationCallback(
  _ display: CGDirectDisplayID,
  _ flags: CGDisplayChangeSummaryFlags,
  _ userInfo: UnsafeMutableRawPointer?
) {
  guard let userInfo else { return }
  // Preserve affected display, complete flags, and begin/end transaction state.
  // Multiple callbacks may fire for one physical action; treat as event stream.
  let observer = Unmanaged<DisplayReconfigurationObserver>
    .fromOpaque(userInfo)
    .takeUnretainedValue()
  let rawFlags = flags.rawValue
  let isBegin = flags.contains(.beginConfigurationFlag)
  Task { @MainActor in
    observer.notify(displayID: display, flags: rawFlags, isBegin: isBegin)
  }
}

/// Event-stream observer: emits affected display + flags + begin/end + local
/// generation + timestamp. Flags are never discarded; readable decoding lives
/// in EmberCore.DisplayReconfigurationEvent.
final class DisplayReconfigurationObserver: @unchecked Sendable {
  private let handler: @MainActor @Sendable (DisplayObserverEvent) -> Void
  private var generation: UInt64 = 0
  private let lock = NSLock()

  init(handler: @escaping @MainActor @Sendable (DisplayObserverEvent) -> Void) {
    self.handler = handler
    CGDisplayRegisterReconfigurationCallback(
      emberDisplayReconfigurationCallback,
      Unmanaged.passUnretained(self).toOpaque()
    )
  }

  deinit {
    CGDisplayRemoveReconfigurationCallback(
      emberDisplayReconfigurationCallback,
      Unmanaged.passUnretained(self).toOpaque()
    )
  }

  @MainActor
  func notify(displayID: CGDirectDisplayID, flags: UInt32, isBegin: Bool) {
    lock.lock()
    generation += 1
    let current = generation
    lock.unlock()
    handler(DisplayObserverEvent(
      displayID: displayID, flags: flags, isBeginTransaction: isBegin,
      generation: current, timestamp: Date()))
  }
}

struct DisplayObserverEvent: Sendable {
  let displayID: UInt32
  let flags: UInt32
  let isBeginTransaction: Bool
  let generation: UInt64
  let timestamp: Date
}
