import AppKit

@MainActor
final class EmberSwitch: NSControl {
  private let trackLayer = CALayer()
  private let thumbLayer = CALayer()
  private let thumbShadow = CALayer()

  var isOn: Bool = false {
    didSet { if oldValue != isOn { updateVisual(animated: true) } }
  }

  var state: NSControl.StateValue {
    get { isOn ? .on : .off }
    set {
      if isOn != (newValue == .on) {
        isOn = (newValue == .on)
        updateVisual(animated: false)
      }
    }
  }

  func setOn(_ on: Bool, animated: Bool) {
    guard isOn != on else { return }
    isOn = on
    updateVisual(animated: animated)
  }

  private var isPressed = false

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 26))
    wantsLayer = true
    layer?.masksToBounds = false

    trackLayer.cornerRadius = 13
    trackLayer.masksToBounds = true
    trackLayer.borderWidth = 1
    trackLayer.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor

    thumbLayer.cornerRadius = 11
    thumbLayer.backgroundColor = NSColor.white.cgColor
    thumbLayer.shadowColor = NSColor.black.cgColor
    thumbLayer.shadowOpacity = 0.28
    thumbLayer.shadowRadius = 4
    thumbLayer.shadowOffset = CGSize(width: 0, height: 1)
    thumbLayer.masksToBounds = false

    if let l = layer {
      l.addSublayer(trackLayer)
      l.addSublayer(thumbLayer)
    }

    updateVisual(animated: false)
    setAccessibilityRole(.checkBox)
    setAccessibilityLabel("Toggle")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 26) }

  override func layout() {
    super.layout()
    trackLayer.frame = bounds
    trackLayer.cornerRadius = bounds.height/2
    let thumbSize: CGFloat = 22
    let y = (bounds.height - thumbSize)/2
    let xOn = bounds.width - thumbSize - 2
    let xOff: CGFloat = 2
    let targetX = isOn ? xOn : xOff
    thumbLayer.frame = NSRect(x: targetX, y: y, width: thumbSize, height: thumbSize)
    thumbLayer.cornerRadius = thumbSize/2
  }

  private func updateVisual(animated: Bool) {
    let onColor = EmberColor.ember500.cgColor
    let offColor = NSColor(calibratedWhite: 0.26, alpha: 1.0).cgColor
    let borderOn = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.30, alpha: 0.22).cgColor
    let borderOff = NSColor.white.withAlphaComponent(0.06).cgColor

    if animated && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      let colorAnim = CABasicAnimation(keyPath: "backgroundColor")
      colorAnim.fromValue = trackLayer.backgroundColor
      colorAnim.toValue = isOn ? onColor : offColor
      colorAnim.duration = 0.22
      colorAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      trackLayer.add(colorAnim, forKey: "bg")
    }
    trackLayer.backgroundColor = isOn ? onColor : offColor
    trackLayer.borderColor = isOn ? borderOn : borderOff

    if animated && window != nil {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.22
        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layoutSubtreeIfNeeded()
        self.layout()
      }
    } else {
      needsLayout = true
    }
    setAccessibilityValue(isOn ? "On" : "Off")
  }

  private func sendActionIfNeeded() {
    if let t = target, let a = action {
      NSApp.sendAction(a, to: t, from: self)
    }
  }

  override func mouseDown(with event: NSEvent) { isPressed = true }
  override func mouseUp(with event: NSEvent) {
    guard isPressed else { return }
    isPressed = false
    guard isEnabled else { return }
    isOn.toggle()
    needsLayout = true
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    sendActionIfNeeded()
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 49 || event.keyCode == 36 {
      isOn.toggle()
      sendActionIfNeeded()
    } else { super.keyDown(with: event) }
  }
  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool { true }
  override func resignFirstResponder() -> Bool { true }
  override func drawFocusRingMask() {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: -2, dy: -2), xRadius: bounds.height/2 + 2, yRadius: bounds.height/2 + 2)
    path.fill()
  }
  override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: -3, dy: -3) }
  override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
  override func isAccessibilityEnabled() -> Bool { isEnabled }
  func setState(_ s: NSControl.StateValue) {
    state = s
    updateVisual(animated: false)
  }
}

@MainActor
final class EmberToggleRowView: NSView {
  let iconView = NSImageView()
  let titleLabel = NSTextField(labelWithString: "")
  let detailLabel = NSTextField(wrappingLabelWithString: "")
  let captionLabel = NSTextField(labelWithString: "")
  let toggle = EmberSwitch()
  var actionButton: NSButton?

  init(iconSymbol: String, title: String, detail: String) {
    super.init(frame: .zero)
    wantsLayer = true

    iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    iconView.contentTintColor = EmberColor.textTertiary
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true
    iconView.heightAnchor.constraint(equalToConstant: 20).isActive = true
    iconView.imageScaling = .scaleProportionallyDown
    if let img = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: title) {
      iconView.image = img
    }

    titleLabel.stringValue = title
    titleLabel.font = EmberFont.rowTitle()
    titleLabel.textColor = EmberColor.textPrimary
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentHuggingPriority(.required, for: .vertical)
    titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

    detailLabel.stringValue = detail
    detailLabel.font = EmberFont.rowDetail()
    detailLabel.textColor = EmberColor.textSecondary
    detailLabel.maximumNumberOfLines = 2
    detailLabel.preferredMaxLayoutWidth = 244
    detailLabel.lineBreakMode = .byWordWrapping
    detailLabel.setContentHuggingPriority(.defaultLow, for: .vertical)

    captionLabel.font = EmberFont.rowCaption()
    captionLabel.textColor = EmberColor.textMuted
    captionLabel.isHidden = true
    captionLabel.maximumNumberOfLines = 2
    captionLabel.lineBreakMode = .byWordWrapping
    captionLabel.preferredMaxLayoutWidth = 244
    captionLabel.setContentHuggingPriority(.defaultLow, for: .vertical)

    let textStack = NSStackView(views: [titleLabel, detailLabel, captionLabel])
    textStack.orientation = .vertical
    textStack.spacing = 2
    textStack.alignment = .leading
    textStack.translatesAutoresizingMaskIntoConstraints = false
    textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
    textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    textStack.setContentHuggingPriority(.required, for: .vertical)
    textStack.setContentCompressionResistancePriority(.required, for: .vertical)

    toggle.translatesAutoresizingMaskIntoConstraints = false
    toggle.widthAnchor.constraint(equalToConstant: 44).isActive = true
    toggle.heightAnchor.constraint(equalToConstant: 26).isActive = true
    toggle.setContentHuggingPriority(.required, for: .horizontal)
    toggle.setContentCompressionResistancePriority(.required, for: .horizontal)

    // Fixed row height 81, but allow growth for location button case.
    // Icon and toggle are centered to the row, textStack is top-pinned so title never shifts when detail wraps 1↔2 lines.
    addSubview(iconView)
    addSubview(textStack)
    addSubview(toggle)
    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 20),
      iconView.heightAnchor.constraint(equalToConstant: 20),

      toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
      toggle.widthAnchor.constraint(equalToConstant: 44),
      toggle.heightAnchor.constraint(equalToConstant: 26),

      textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
      textStack.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -12),
      textStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
      textStack.widthAnchor.constraint(lessThanOrEqualToConstant: 244),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 81),
    ])
    let h81 = heightAnchor.constraint(equalToConstant: 81)
    h81.priority = .defaultHigh
    h81.isActive = true
    // Ensure textStack doesn't compress toggle
    textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func setCaption(_ text: String?, color: NSColor = EmberColor.textMuted, showButton: Bool = false, buttonTitle: String? = nil, target: AnyObject? = nil, action: Selector? = nil) {
    if let t = text, !t.isEmpty {
      captionLabel.stringValue = t
      captionLabel.textColor = color
      captionLabel.isHidden = false
    } else {
      captionLabel.isHidden = true
    }
    if showButton {
      if actionButton == nil {
        let b = NSButton(title: buttonTitle ?? "Open Location Settings…", target: target, action: action)
        b.bezelStyle = .inline
        b.font = .systemFont(ofSize: 9.5, weight: .medium)
        b.contentTintColor = EmberColor.ember400
        b.translatesAutoresizingMaskIntoConstraints = false
        if let textStack = captionLabel.superview as? NSStackView {
          textStack.addArrangedSubview(b)
          b.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        actionButton = b
      }
      actionButton?.isHidden = false
      actionButton?.title = buttonTitle ?? "Open Location Settings…"
      actionButton?.target = target as AnyObject?
      actionButton?.action = action
    } else {
      actionButton?.isHidden = true
    }
  }
}

@MainActor
final class EmberSettingsCard: NSView {
  private let stack = NSStackView()
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = EmberMetrics.cardCorner
    layer?.masksToBounds = true
    layer?.backgroundColor = EmberColor.surfaceCard.cgColor
    layer?.borderWidth = 1
    layer?.borderColor = EmberColor.borderCard.cgColor
    stack.orientation = .vertical
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
  func addRow(_ row: EmberToggleRowView, showDivider: Bool = true) {
    stack.addArrangedSubview(row)
    if showDivider {
      let div = NSView()
      div.wantsLayer = true
      div.layer?.backgroundColor = EmberColor.divider.cgColor
      div.translatesAutoresizingMaskIntoConstraints = false
      div.heightAnchor.constraint(equalToConstant: 1).isActive = true
      stack.addArrangedSubview(div)
    }
  }
}
