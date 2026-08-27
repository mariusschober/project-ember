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
      resetHandler: { [weak coordinator] in
        coordinator?.resetDisplayNow()
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
    button.action = #selector(togglePopover)
    button.imagePosition = .imageOnly
    button.toolTip = "Project Ember"
    button.setAccessibilityLabel("Project Ember display controls")
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

    displayObserver = DisplayReconfigurationObserver { [weak coordinator] in
      coordinator?.displayConfigurationChanged()
    }
  }

  private func renderStatusItem(_ snapshot: EmberSnapshot) {
    guard let button = statusItem.button else { return }
    let image: NSImage
    let description: String
    // Use runtimeState directly; string-based check was brittle and duplicated
    // logic already handled in DisplayCoordinator snapshot for pending restores.
    switch snapshot.runtimeState {
    case .active:
      image = EmberDotIcon.activeImage()
      description = "Project Ember active"
    case .degraded:
      // Degraded with pending-only (disconnected) is rendered as off in snapshot,
      // so any remaining degraded is a genuine attention state.
      image = EmberDotIcon.degradedImage()
      description = "Project Ember needs attention"
    case .activating, .restoring:
      image = EmberDotIcon.inactiveImage()
      description = "Project Ember working"
    default:
      // Off / suspended — check title only for the generic "Needs attention" that
      // may still come from .off with lastError (not pending). Prefer runtimeState
      // but keep fallback for .off degraded-style lastError.
      if snapshot.statusTitle == "Needs attention" {
        image = EmberDotIcon.degradedImage()
        description = "Project Ember needs attention"
      } else {
        image = EmberDotIcon.inactiveImage()
        description = "Project Ember ready"
      }
    }
    button.image = image
    button.image?.isTemplate = false
    // Ensure crisp on Retina
    button.image?.size = NSSize(width: 16, height: 16)
    button.toolTip = description
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
      showPopover()
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
  guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
  // Observer is guaranteed to outlive registration (owned by AppDelegate for the
  // entire process lifetime). Use unretained to avoid retain/release in the
  // callback which runs on an arbitrary thread.
  let observer = Unmanaged<DisplayReconfigurationObserver>
    .fromOpaque(userInfo)
    .takeUnretainedValue()
  Task { @MainActor in
    observer.notify()
  }
}

final class DisplayReconfigurationObserver: @unchecked Sendable {
  private let handler: @MainActor @Sendable () -> Void

  init(handler: @escaping @MainActor @Sendable () -> Void) {
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
  func notify() {
    handler()
  }
}
