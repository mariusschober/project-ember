import AppKit

@MainActor
final class EmberPillControl: NSView {
  private let container = NSView()
  private var buttons: [NSButton] = []
  private var indicator = NSView()
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
    indicator.layer?.cornerRadius = 15
    indicator.layer?.masksToBounds = true
    indicator.layer?.backgroundColor = NSColor.clear.cgColor
    // gradient layer for selected
    let grad = CAGradientLayer()
    grad.colors = [
      NSColor(calibratedRed: 0.78, green: 0.20, blue: 0.09, alpha: 1.0).cgColor,
      NSColor(calibratedRed: 0.62, green: 0.16, blue: 0.08, alpha: 1.0).cgColor,
    ]
    grad.startPoint = CGPoint(x: 0, y: 0.5)
    grad.endPoint = CGPoint(x: 1, y: 0.5)
    grad.name = "indicatorGrad"
    indicator.layer?.insertSublayer(grad, at: 0)

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
    needsLayout = true
  }

  private var stackView: NSStackView!

  override func layout() {
    super.layout()
    // Ensure stack and container have laid out before measuring button frames
    stackView?.layoutSubtreeIfNeeded()
    container.layoutSubtreeIfNeeded()
    container.layer?.cornerRadius = container.bounds.height / 2
    // Selected background breathing room: 5-6pt outer inset is provided by the
    // stack 3pt padding + indicator inset; add 1-2pt internal inset via frame.
    // Position indicator
    guard selectedSegment >= 0, selectedSegment < buttons.count else {
      indicator.isHidden = true
      // Custom warmth: reset ALL labels to unselected style (no stale white/semibold).
      for b in buttons {
        b.contentTintColor = EmberColor.textSecondary
        b.font = EmberFont.pill()
      }
      return
    }
    indicator.isHidden = false
    let btn = buttons[selectedSegment]
    // Guard against zero frames during initial layout pass — defer
    guard btn.frame.width > 0 else {
      indicator.isHidden = true
      DispatchQueue.main.async { [weak self] in self?.needsLayout = true }
      return
    }
    let frame = container.convert(btn.frame, from: btn.superview)
    // Breathing room: outer gap from the container edge comes from the stack
    // inset; the indicator additionally insets from the segment frame so the
    // highlight never hugs the label or touches the container border.
    let target = NSRect(
      x: frame.minX + EmberMetrics.pillIndicatorHInset,
      y: frame.minY + EmberMetrics.pillIndicatorVInset,
      width: frame.width - (EmberMetrics.pillIndicatorHInset * 2),
      height: frame.height - (EmberMetrics.pillIndicatorVInset * 2))
    guard target.width > 0, target.height > 0 else {
      indicator.isHidden = true
      return
    }
    indicator.frame = target
    if let grad = indicator.layer?.sublayers?.first(where: { $0.name == "indicatorGrad" }) {
      grad.frame = indicator.bounds
      grad.cornerRadius = indicator.bounds.height / 2
    }
    indicator.layer?.cornerRadius = indicator.bounds.height / 2

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

  func setSelectedSegment(_ index: Int, animated: Bool) {
    guard index != selectedSegment else {
      // Still refresh layout so custom (-1) clears stale highlight.
      if index == -1 { needsLayout = true }
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
    // didSet schedules layout; do not call layout() directly (single path).
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
