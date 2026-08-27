import AppKit

@MainActor
final class EmberPillControl: NSView {
  private let container = NSView()
  private var buttons: [NSButton] = []
  private var indicator = NSView()
  private let titles: [String]
  var onSelect: ((Int) -> Void)?

  private(set) var selectedSegment: Int = -1 {
    didSet { updateSelection(animated: true) }
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
    grad.cornerRadius = 15
    grad.name = "indicatorGrad"
    indicator.layer?.insertSublayer(grad, at: 0)

    // subtle inner highlight
    let hl = CALayer()
    hl.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
    hl.cornerRadius = 15
    hl.frame = NSRect(x: 0, y: 13, width: 100, height: 1)
    hl.name = "hl"
    indicator.layer?.addSublayer(hl)

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

      if idx < titles.count - 1 {
        // divider
        let div = NSView()
        div.wantsLayer = true
        div.layer?.backgroundColor = EmberColor.divider.cgColor
        div.translatesAutoresizingMaskIntoConstraints = false
        div.widthAnchor.constraint(equalToConstant: 1).isActive = true
        // divider height 18 centered vertically - add to stack as view? instead overlay
        // We'll add as separate view inside container and position later, but for stack distribution we insert a wrapper
        // Simpler: not using divider in stack, will draw via layer separators drawn in layout
      }
    }

    container.addSubview(stack)

    NSLayoutConstraint.activate([
      container.leadingAnchor.constraint(equalTo: leadingAnchor),
      container.trailingAnchor.constraint(equalTo: trailingAnchor),
      container.topAnchor.constraint(equalTo: topAnchor),
      container.bottomAnchor.constraint(equalTo: bottomAnchor),
      container.heightAnchor.constraint(equalToConstant: 36),

      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -3),
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),

      heightAnchor.constraint(equalToConstant: 36),
    ])

    // Need to keep stack reference for layout? recreate ivar
    self.stackView = stack
    updateSelection(animated: false)
  }

  private var stackView: NSStackView!

  override func layout() {
    super.layout()
    // Ensure stack and container have laid out before measuring button frames
    stackView?.layoutSubtreeIfNeeded()
    container.layoutSubtreeIfNeeded()
    container.layer?.cornerRadius = container.bounds.height / 2
    // Position indicator
    guard selectedSegment >= 0, selectedSegment < buttons.count else {
      indicator.isHidden = true
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
    let target = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    indicator.frame = target
    if let grad = indicator.layer?.sublayers?.first(where: { $0.name == "indicatorGrad" }) {
      grad.frame = indicator.bounds
      grad.cornerRadius = indicator.bounds.height/2
    }
    if let hl = indicator.layer?.sublayers?.first(where: { $0.name == "hl" }) {
      hl.frame = NSRect(x: 1, y: indicator.bounds.height - 1, width: indicator.bounds.width - 2, height: 1)
      hl.cornerRadius = 0.5
    }
    indicator.layer?.cornerRadius = indicator.bounds.height/2

    // Update button colors
    for (idx, b) in buttons.enumerated() {
      let selected = idx == selectedSegment
      b.contentTintColor = selected ? .white : EmberColor.textSecondary
      b.font = selected ? EmberFont.pillSelected() : EmberFont.pill()
      b.alphaValue = 1
    }
    // Dim dividers when selection covers? keep subtle
    container.layer?.borderColor = EmberColor.borderSubtle.cgColor
  }

  func setSelectedSegment(_ index: Int, animated: Bool) {
    guard index != selectedSegment else { return }
    if !animated {
      NSAnimationContext.current.duration = 0
    }
    selectedSegment = index
    if !animated {
      layout()
    }
  }

  private func updateSelection(animated: Bool) {
    needsLayout = true
    // Defer layout to next pass, avoid re-entrancy during constraint activation
    if window != nil {
      needsLayout = true
    }
  }

  @objc private func tap(_ sender: NSButton) {
    let idx = sender.tag
    guard idx != selectedSegment else { return }
    selectedSegment = idx
    // send action to target if set, or via onSelect
    if let target = target, let action = action {
      NSApp.sendAction(action, to: target, from: self)
    }
    onSelect?(idx)
  }

  // MARK: - Target/Action compatibility
  weak var target: AnyObject?
  var action: Selector?

  func setTarget(_ t: AnyObject?, action: Selector?) {
    self.target = t
    self.action = action
  }

}
