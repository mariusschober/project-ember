import AppKit

@MainActor
final class DiagnosticsWindowController: NSWindowController {
  private let textView = NSTextView()
  private let textProvider: () -> String
  private let exportProvider: () -> String
  private let resetHandler: () -> Void
  private let retryHandler: () -> Void

  init(
    textProvider: @escaping () -> String,
    exportProvider: @escaping () -> String = { "" },
    resetHandler: @escaping () -> Void,
    retryHandler: @escaping () -> Void = {}
  ) {
    self.textProvider = textProvider
    self.exportProvider = exportProvider
    self.resetHandler = resetHandler
    self.retryHandler = retryHandler

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Project Ember Diagnostics"
    window.minSize = NSSize(width: 500, height: 300)
    super.init(window: window)
    buildContent()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func present() {
    textView.string = textProvider()
    showWindow(nil)
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func buildContent() {
    guard let contentView = window?.contentView else { return }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)

    let intro = NSTextField(
      wrappingLabelWithString:
        "Local-only event history (display IDs, generations, journal outcomes, verification deltas). No screenshots, window titles, filenames, or browsing data. Identifiers are labeled before export.")
    intro.font = .systemFont(ofSize: 12)
    intro.textColor = .secondaryLabelColor

    textView.isEditable = false
    textView.isSelectable = true
    textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.string = textProvider()
    textView.setAccessibilityLabel("Diagnostics log")
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.documentView = textView

    let reset = NSButton(
      title: "Restore Display Now", target: self, action: #selector(resetDisplay))
    reset.bezelStyle = .rounded
    reset.contentTintColor = .systemOrange
    reset.setAccessibilityLabel("Restore Display Now")
    reset.setAccessibilityHelp("Restores saved baselines. Disconnected entries remain pending.")
    let retry = NSButton(title: "Retry", target: self, action: #selector(retryNow))
    retry.bezelStyle = .rounded
    retry.setAccessibilityLabel("Retry verification")
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let copy = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnostics))
    copy.bezelStyle = .rounded
    copy.setAccessibilityLabel("Copy Diagnostics")
    let export = NSButton(title: "Export Diagnostics…", target: self, action: #selector(exportDiagnostics))
    export.bezelStyle = .rounded
    export.setAccessibilityLabel("Export Diagnostics")
    let buttons = NSStackView(views: [reset, retry, spacer, copy, export])
    buttons.orientation = .horizontal
    buttons.alignment = .centerY
    buttons.spacing = 8

    stack.addArrangedSubview(intro)
    stack.addArrangedSubview(scroll)
    stack.addArrangedSubview(buttons)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
      intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
      scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
      scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
      buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
  }

  @objc private func copyDiagnostics() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(textProvider(), forType: .string)
    textView.string = textProvider()
  }

  @objc private func exportDiagnostics() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "ember-diagnostics.txt"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      let text = self?.exportProvider() ?? self?.textProvider() ?? ""
      try? text.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  @objc private func retryNow() {
    retryHandler()
    textView.string = textProvider()
  }

  @objc private func resetDisplay() {
    resetHandler()
    textView.string = textProvider()
  }
}
