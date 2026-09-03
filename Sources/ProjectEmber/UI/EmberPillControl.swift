import AppKit

@MainActor
final class EmberPillControl: NSView {
  private let container = NSView()
  private var buttons: [NSButton] = []
  private let indicator = PillIndicatorView()
  private var indicatorConstraints: [NSLayoutConstraint] = []
  private let titles: [String]
  var onSelect: ((Int) -> Void)?

  private(set) var selectedSegment: Int = -1 {
    didSet { needsLayout = true }
  }

  // Compatibility with original NSSegmentedControl API
  var isEnabled: Bool = true {
    didSet {
      buttons.forEach { $0.isEnabled = isEnabled }
      alphaValue = isEnabled ? 1 : 0.45
    }
  }

  init(titles: [String] = ["Neutral", "Evening", "Pure Red"]) {
    self.titles = titles
    super.init(frame: .zero)
    wantsLayer = true
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  private func setup() {
    container.wantsLayer = true
    container.layer?.cornerRadius = EmberMetrics.pillCorner
    container.layer?.masksToBounds = true
    container.layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1.0).cgColor
    container.layer?.borderWidth = 1
    container.layer?.borderColor = EmberColor.borderSubtle.cgColor
    container.translatesAutoresizingMaskIntoConstraints = false
    addSubview(container)

    indicator.wantsLayer = true
    indicator.translatesAutoresizingMaskIntoConstraints = false
    indicator.layer?.shadowColor = NSColor.black.cgColor
    indicator.layer?.shadowOpacity = 0.28
    indicator.layer?.shadowRadius = 6
    indicator.layer?.shadowOffset = CGSize(width: 0, height: 2)

    container.addSubview(indicator)

    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.distribution = .fillEqually
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false

    for (idx, title) in titles.enumerated() {
      let b = NSButton(title: title, target: self, action: #selector(tap(_:)))
      b.bezelStyle = .inline
      b.isBordered = false
      b.font = EmberFont.pill()
      b.contentTintColor = EmberColor.textSecondary
      b.tag = idx
      b.translatesAutoresizingMaskIntoConstraints = false
      b.setButtonType(.momentaryChange)
      // remove default bezel
      b.wantsLayer = true
      b.layer?.backgroundColor = NSColor.clear.cgColor
      // For accessibility
      b.setAccessibilityLabel(title)
      buttons.append(b)
      stack.addArrangedSubview(b)
    }

    container.addSubview(stack)

    NSLayoutConstraint.activate([
      container.leadingAnchor.constraint(equalTo: leadingAnchor),
      container.trailingAnchor.constraint(equalTo: trailingAnchor),
      container.topAnchor.constraint(equalTo: topAnchor),
      container.bottomAnchor.constraint(equalTo: bottomAnchor),
      container.heightAnchor.constraint(equalToConstant: EmberMetrics.pillHeight),

      stack.leadingAnchor.constraint(
        equalTo: container.leadingAnchor, constant: EmberMetrics.pillStackInset),
      stack.trailingAnchor.constraint(
        equalTo: container.trailingAnchor, constant: -EmberMetrics.pillStackInset),
      stack.topAnchor.constraint(
        equalTo: container.topAnchor, constant: EmberMetrics.pillStackInset),
      stack.bottomAnchor.constraint(
        equalTo: container.bottomAnchor, constant: -EmberMetrics.pillStackInset),

      heightAnchor.constraint(equalToConstant: EmberMetrics.pillHeight),
    ])

    // Hover tracking for unselected segments (matches the hero orb hover language).
    let tracking = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(tracking)

    // Need to keep stack reference for layout? recreate ivar
    self.stackView = stack
    remakeIndicatorConstraints(animated: false)
    needsLayout = true
  }

  private var stackView: NSStackView!

  override func layout() {
    super.layout()
    // Ensure stack and container have laid out before styling; the indicator
    // itself is constraint-pinned (see remakeIndicatorConstraints), so no
    // manual frame math here and no stale-frame class of bug.
    stackView?.layoutSubtreeIfNeeded()
    container.layoutSubtreeIfNeeded()
    container.layer?.cornerRadius = container.bounds.height / 2
    guard selectedSegment >= 0, selectedSegment < buttons.count else {
      // Custom warmth: hide the highlight and reset ALL labels to unselected
      // style (no stale white/semibold).
      indicator.isHidden = true
      for b in buttons {
        b.contentTintColor = EmberColor.textSecondary
        b.font = EmberFont.pill()
      }
      return
    }

    // Update button colors — Increase Contrast: keep white + semibold + indicator
    // border so selected state never relies on color alone. Hovered unselected
    // segments brighten slightly (Reduce-Motion-safe: instant tint, no animation).
    for (idx, b) in buttons.enumerated() {
      let selected = idx == selectedSegment
      if selected {
        b.contentTintColor = .white
        b.font = EmberFont.pillSelected()
      } else if idx == hoveredSegment, isEnabled {
        b.contentTintColor = EmberColor.textPrimary
        b.font = EmberFont.pill()
      } else {
        b.contentTintColor = EmberColor.textSecondary
        b.font = EmberFont.pill()
      }
      b.alphaValue = 1
    }
    if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
      indicator.layer?.borderWidth = 1
      indicator.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
    } else {
      indicator.layer?.borderWidth = 0
    }
    // Dim dividers when selection covers? keep subtle
    container.layer?.borderColor = EmberColor.borderSubtle.cgColor
  }

  private var hoveredSegment: Int = -1

  /// Pins the highlight to the selected segment button with small breathing
  /// insets. Cross-hierarchy anchors (indicator in the container, button in
  /// the stack) share the container as common ancestor, so the highlight
  /// tracks the button through every layout pass — no manual frames, no
  /// stale-frame deferrals.
  private func remakeIndicatorConstraints(animated: Bool) {
    NSLayoutConstraint.deactivate(indicatorConstraints)
    indicatorConstraints.removeAll()
    guard selectedSegment >= 0, selectedSegment < buttons.count else {
      indicator.isHidden = true
      return
    }
    indicator.isHidden = false
    let btn = buttons[selectedSegment]
    indicatorConstraints = [
      indicator.leadingAnchor.constraint(
        equalTo: btn.leadingAnchor, constant: EmberMetrics.pillIndicatorHInset),
      indicator.trailingAnchor.constraint(
        equalTo: btn.trailingAnchor, constant: -EmberMetrics.pillIndicatorHInset),
      indicator.topAnchor.constraint(
        equalTo: btn.topAnchor, constant: EmberMetrics.pillIndicatorVInset),
      indicator.bottomAnchor.constraint(
        equalTo: btn.bottomAnchor, constant: -EmberMetrics.pillIndicatorVInset),
    ]
    NSLayoutConstraint.activate(indicatorConstraints)
    if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { _ in
        container.layoutSubtreeIfNeeded()
      }
    } else {
      container.needsLayout = true
    }
  }

  func setSelectedSegment(_ index: Int, animated: Bool) {
    guard index != selectedSegment else {
      // Still refresh so custom (-1) clears a stale highlight.
      if index == -1 { remakeIndicatorConstraints(animated: false); needsLayout = true }
      return
    }
    // Honor animated truthfully: suppress implicit animations when false,
    // including Reduce Motion.
    let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if !shouldAnimate {
      NSAnimationContext.beginGrouping()
      NSAnimationContext.current.duration = 0
    }
    selectedSegment = index
    updateAccessibility(index)
    // Re-pin the highlight (single update path; layout follows automatically).
    remakeIndicatorConstraints(animated: animated)
    if !shouldAnimate {
      NSAnimationContext.endGrouping()
    }
  }

  private func updateAccessibility(_ index: Int) {
    setAccessibilityRole(.radioGroup)
    setAccessibilityLabel("Color preset")
    let names = titles
    if index >= 0, index < names.count {
      setAccessibilityValue(names[index])
    } else {
      setAccessibilityValue("Custom warmth")
    }
  }

  @objc private func tap(_ sender: NSButton) {
    let idx = sender.tag
    guard idx != selectedSegment else { return }
    guard isEnabled else { return }
    // Single update path: setSelectedSegment owns selection + layout.
    setSelectedSegment(idx, animated: true)
    // send action to target if set, or via onSelect
    if let target = target, let action = action {
      NSApp.sendAction(action, to: target, from: self)
    }
    onSelect?(idx)
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    guard isEnabled else { return }
    let point = convert(event.locationInWindow, from: nil)
    var hovered = -1
    for (idx, b) in buttons.enumerated() where idx != selectedSegment {
      if b.frame.contains(convert(point, to: b.superview)) { hovered = idx; break }
    }
    if hovered != hoveredSegment {
      hoveredSegment = hovered
      needsLayout = true
    }
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    if hoveredSegment != -1 { hoveredSegment = -1; needsLayout = true }
  }

  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool { true }
  override func keyDown(with event: NSEvent) {
    // Arrow-key navigation for segmented/radio-group semantics.
    if event.keyCode == 123 || event.keyCode == 124 {
      let delta = event.keyCode == 124 ? 1 : -1
      let count = buttons.count
      guard count > 0 else { super.keyDown(with: event); return }
      let next = ((selectedSegment < 0 ? (delta > 0 ? -1 : 0) : selectedSegment) + delta + count) % count
      setSelectedSegment(next, animated: true)
      tap(buttons[next])
      return
    }
    super.keyDown(with: event)
  }

  override func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }

  // MARK: - Target/Action compatibility
  weak var target: AnyObject?
  var action: Selector?

  func setTarget(_ t: AnyObject?, action: Selector?) {
    self.target = t
    self.action = action
  }

}

/// Highlight bar behind the selected preset. Owns its gradient and keeps it
/// glued to its own bounds, so no outer layout code ever sizes sublayers.
@MainActor
final class PillIndicatorView: NSView {
  private let gradient = CAGradientLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
    gradient.colors = [
      NSColor(calibratedRed: 0.78, green: 0.20, blue: 0.09, alpha: 1.0).cgColor,
      NSColor(calibratedRed: 0.62, green: 0.16, blue: 0.08, alpha: 1.0).cgColor,
    ]
    gradient.startPoint = CGPoint(x: 0, y: 0.5)
    gradient.endPoint = CGPoint(x: 1, y: 0.5)
    if let layer { layer.addSublayer(gradient) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    gradient.frame = bounds
    gradient.cornerRadius = bounds.height / 2
    layer?.cornerRadius = bounds.height / 2
  }
}
