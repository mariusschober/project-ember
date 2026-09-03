import AppKit
import CoreGraphics
import EmberCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let coordinator: DisplayCoordinator
  private var statusItem: NSStatusItem!
  private let popover = NSPopover()
  private var panelController: ControlPanelViewController!
  private var diagnosticsController: DiagnosticsWindowController!
  private var workspaceObservers: [NSObjectProtocol] = []
  private var systemObservers: [NSObjectProtocol] = []
  private var displayObserver: DisplayReconfigurationObserver?
  private var qaWindow: NSWindow?
  private var visualQAMode = false

  override init() {
    let isVisualQA =
      CommandLine.arguments.contains("--show-panel")
      || CommandLine.arguments.contains("--snapshot-ui")
    if isVisualQA,
      let defaults = UserDefaults(suiteName: "app.projectember.visual-qa")
    {
      coordinator = DisplayCoordinator(
        settingsStore: SettingsStore(defaults: defaults),
        solarController: SolarScheduleController(
          locationStore: SolarLocationStore(defaults: defaults)
        )
      )
    } else {
      coordinator = DisplayCoordinator()
    }
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    visualQAMode =
      CommandLine.arguments.contains("--show-panel")
      || CommandLine.arguments.contains("--snapshot-ui")
    NSApp.setActivationPolicy(visualQAMode ? .regular : .accessory)
    setupDiagnostics()
    setupPanel()
    setupStatusItem()
    setupLifecycleObservers()

    coordinator.onSnapshot = { [weak self] snapshot in
      self?.panelController.render(snapshot)
      self?.renderStatusItem(snapshot)
    }
    coordinator.start()
    panelController.render(coordinator.currentSnapshot())
    renderStatusItem(coordinator.currentSnapshot())

    if visualQAMode {
      DispatchQueue.main.async { [weak self] in
        NSApp.activate(ignoringOtherApps: true)
        self?.qaWindow?.center()
        self?.qaWindow?.makeKeyAndOrderFront(nil)
        self?.captureSnapshotIfRequested()
      }
    }
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
    } else {
      popover.behavior = .transient
      popover.animates = true
      popover.appearance = NSAppearance(named: .darkAqua)
      popover.contentSize = panelController.preferredContentSize
      popover.contentViewController = panelController
    }
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
    button.setAccessibilityHelp("Left click follows Menu bar click setting. Right click always opens controls.")
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
    button.image = image
    button.image?.isTemplate = false
    button.image?.size = NSSize(width: 16, height: 16)
    button.toolTip = description
    button.setAccessibilityLabel(description)
    button.setAccessibilityValue(value)
    button.setAccessibilityHelp(
      "Left click: \(snapshot.settings.menuBarPrimaryAction == .toggleEmber ? "toggle Ember" : "open controls"). Right click always opens controls."
    )
  }

  @objc private func statusItemClicked() {
    guard let event = NSApp.currentEvent else {
      togglePopover()
      return
    }
    // Right-click / secondary / two-finger / Control-click always opens controls.
    if event.type == .rightMouseUp {
      openControls()
      return
    }
    if event.type == .leftMouseUp, event.modifierFlags.contains(.control) {
      openControls()
      return
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

  private func openControls() {
    if visualQAMode {
      qaWindow?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    if !popover.isShown { showPopover() }
  }

  @objc private func togglePopover() {
    if visualQAMode {
      qaWindow?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
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
    popover.contentSize = panelController.preferredContentSize
    panelController.render(coordinator.currentSnapshot())
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    if let win = popover.contentViewController?.view.window {
      win.appearance = NSAppearance(named: .darkAqua)
    }
  }

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
