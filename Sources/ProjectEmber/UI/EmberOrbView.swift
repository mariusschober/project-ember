import AppKit

@MainActor
final class EmberOrbView: NSView {
  private let orbLayer = CALayer()
  private let glowLayer = CALayer()
  private let highlightLayer = CALayer()
  private var waveLayers: [CAShapeLayer] = []
  private var waveBaseOpacity: [Float] = []
  private var isActive = false
  private var pulsing = false
  // Button state: the hero orb is the panel's on/off control. Hover previews
  // the toggle result (capped partial mix, never the full opposite state).
  private var isHovered = false
  private var isPressed = false
  private var cursorPushed = false
  private var trackingArea: NSTrackingArea?
  /// Capped hover-preview mix toward the opposite state (0…1).
  private let hoverMix: CGFloat = 0.4
  var isControlEnabled = true
  var onToggle: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = false

    // Glow outer
    glowLayer.cornerRadius = 44
    glowLayer.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.24, blue: 0.13, alpha: 0.22).cgColor
    glowLayer.masksToBounds = false
    glowLayer.shadowColor = NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.18, alpha: 1.0).cgColor
    glowLayer.shadowRadius = 22
    glowLayer.shadowOpacity = 0.9
    glowLayer.shadowOffset = .zero

    // Orb body with radial gradient via CAGradientLayer trick - use gradient layer
    let gradient = CAGradientLayer()
    gradient.type = .radial
    // Initial state is inactive (grey) until setActive(true) is called
    gradient.colors = [
      NSColor(calibratedWhite: 0.52, alpha: 1.0).cgColor,
      NSColor(calibratedWhite: 0.42, alpha: 1.0).cgColor,
      NSColor(calibratedWhite: 0.32, alpha: 1.0).cgColor,
    ]
    gradient.locations = [0, 0.55, 1]
    gradient.startPoint = CGPoint(x: 0.35, y: 0.35)
    gradient.endPoint = CGPoint(x: 1, y: 1)
    gradient.cornerRadius = 36

    orbLayer.addSublayer(gradient)
    orbLayer.cornerRadius = 36
    orbLayer.masksToBounds = true
    orbLayer.shadowColor = NSColor.black.cgColor
    orbLayer.shadowOpacity = 0.18
    orbLayer.shadowRadius = 8
    orbLayer.shadowOffset = CGSize(width: 0, height: 6)

    // Inner specular highlight: a subtle crescent bound to the orb diameter
    // (never a free-floating capsule).
    highlightLayer.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
    highlightLayer.masksToBounds = true

    // Waves at bottom - three gentle sine-like curves (inactive grey)
    for i in 0..<3 {
      let wave = CAShapeLayer()
      wave.fillColor = NSColor.clear.cgColor
      wave.strokeColor = NSColor(calibratedWhite: 0.45, alpha: 0.06).cgColor
      wave.lineWidth = 0.9
      wave.lineCap = .round
      let base = Float(0.7 - Double(i) * 0.15)
      wave.opacity = base
      waveBaseOpacity.append(base)
      waveLayers.append(wave)
    }

    if let layer {
      layer.addSublayer(glowLayer)
      layer.addSublayer(orbLayer)
      layer.addSublayer(highlightLayer)
      waveLayers.forEach { layer.addSublayer($0) }
      // stash gradient
      orbLayer.setValue(gradient, forKey: "gradient")
    }
    // Ensure initial visual matches inactive
    glowLayer.backgroundColor = NSColor(calibratedWhite: 0.35, alpha: 0.10).cgColor
    glowLayer.opacity = 0.22
    orbLayer.opacity = 0.85
    setAccessibilityRole(.button)
    setAccessibilityLabel("Ember display filter")
    updateAccessibilityValue()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let bounds = self.bounds
    let orbSize: CGFloat = 72
    let orbRect = NSRect(
      x: (bounds.width - orbSize) / 2,
      y: (bounds.height - orbSize) / 2 + 8,
      width: orbSize,
      height: orbSize
    )
    let glowSize = orbSize + 28
    glowLayer.frame = NSRect(
      x: orbRect.midX - glowSize/2,
      y: orbRect.midY - glowSize/2,
      width: glowSize,
      height: glowSize
    )
    glowLayer.cornerRadius = glowSize/2

    orbLayer.frame = orbRect
    if let gradient = orbLayer.value(forKey: "gradient") as? CAGradientLayer {
      gradient.frame = orbLayer.bounds
    }
    highlightLayer.frame = NSRect(
      x: orbRect.minX + orbSize * 0.22,
      y: orbRect.maxY - orbSize * 0.34,
      width: orbSize * 0.36,
      height: orbSize * 0.15
    )
    highlightLayer.cornerRadius = highlightLayer.frame.height / 2

    // waves
    let waveY = orbRect.minY - 6
    let waveWidth = bounds.width * 0.72
    let waveX = (bounds.width - waveWidth)/2
    for (idx, wave) in waveLayers.enumerated() {
      let y = waveY - CGFloat(idx) * 6
      let path = CGMutablePath()
      path.move(to: CGPoint(x: waveX, y: y))
      // two humps
      let segment = waveWidth / 4
      path.addCurve(
        to: CGPoint(x: waveX + segment*2, y: y),
        control1: CGPoint(x: waveX + segment*0.6, y: y + 5),
        control2: CGPoint(x: waveX + segment*1.4, y: y - 5)
      )
      path.addCurve(
        to: CGPoint(x: waveX + waveWidth, y: y),
        control1: CGPoint(x: waveX + segment*2.6, y: y + 4),
        control2: CGPoint(x: waveX + segment*3.4, y: y - 4)
      )
      wave.path = path
      wave.frame = bounds
    }
  }

  // MARK: - Appearance (single path: base state + capped hover preview)

  private static let greyStops: [NSColor] = [
    NSColor(calibratedWhite: 0.52, alpha: 1.0),
    NSColor(calibratedWhite: 0.42, alpha: 1.0),
    NSColor(calibratedWhite: 0.32, alpha: 1.0),
  ]
  private static let emberStops: [NSColor] = [
    NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.22, alpha: 1.0),
    NSColor(calibratedRed: 1.0, green: 0.22, blue: 0.12, alpha: 1.0),
    NSColor(calibratedRed: 0.78, green: 0.14, blue: 0.09, alpha: 1.0),
  ]

  private static func mix(_ from: NSColor, _ to: NSColor, t: CGFloat) -> NSColor {
    let a = from.usingColorSpace(.sRGB) ?? from
    let b = to.usingColorSpace(.sRGB) ?? to
    var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
    var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
    a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
    b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
    return NSColor(
      calibratedRed: ar + ((br - ar) * t),
      green: ag + ((bg - ag) * t),
      blue: ab + ((bb - ab) * t),
      alpha: aa + ((ba - aa) * t))
  }

  func setActive(_ active: Bool, animated: Bool) {
    // Always update visual, even if isActive already equals active — ensures initial off state is grey not orange
    isActive = active
    needsLayout = true
    applyAppearance(animated: animated)
    updateAccessibilityValue()
    toolTip = active ? "Restore original display" : "Apply Ember display filter"
  }

  /// Recomputes gradient stops, glow, and waves from (isActive, isHovered).
  /// Priority: disabled > hover-preview > pulse. Hover mixes only partway
  /// (hoverMix) toward the opposite state so preview can't read as a toggle.
  private func applyAppearance(animated: Bool) {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let shouldAnimate = animated && window != nil && !reduceMotion
    CATransaction.begin()
    CATransaction.setDisableActions(!shouldAnimate)
    CATransaction.setAnimationDuration(0.3)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

    let mixT: CGFloat = (isHovered && isControlEnabled) ? hoverMix : 0
    let base = isActive ? Self.emberStops : Self.greyStops
    let opposite = isActive ? Self.greyStops : Self.emberStops
    if let grad = orbLayer.value(forKey: "gradient") as? CAGradientLayer {
      grad.colors = zip(base, opposite).map { Self.mix($0, $1, t: mixT).cgColor }
    }
    if isActive {
      glowLayer.opacity = isHovered ? 0.75 : 1
      orbLayer.opacity = isPressed ? 0.9 : 1
      glowLayer.backgroundColor = Self.mix(
        NSColor(calibratedRed: 1.0, green: 0.24, blue: 0.13, alpha: 0.28),
        NSColor(calibratedWhite: 0.35, alpha: 0.10), t: mixT
      ).cgColor
    } else {
      glowLayer.opacity = isHovered ? 0.55 : 0.22
      orbLayer.opacity = isPressed ? 0.75 : 0.85
      glowLayer.backgroundColor = Self.mix(
        NSColor(calibratedWhite: 0.35, alpha: 0.10),
        NSColor(calibratedRed: 1.0, green: 0.24, blue: 0.13, alpha: 0.28), t: mixT
      ).cgColor
    }
    highlightLayer.opacity = isHovered ? 1 : 0.8
    for (i, w) in waveLayers.enumerated() {
      let baseAlpha: Float
      if isActive {
        baseAlpha = max(0.05, 0.22 - Float(i) * 0.03)
      } else {
        baseAlpha = 0.06
      }
      // Hover slightly strengthens waves as part of the preview.
      w.opacity = (isHovered && isControlEnabled) ? min(1, baseAlpha + 0.08) : baseAlpha
      let c: NSColor =
        isActive || (isHovered && isControlEnabled)
        ? NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.22, alpha: CGFloat(baseAlpha) + (isHovered ? hoverMix * 0.1 : 0))
        : NSColor(calibratedWhite: 0.45, alpha: CGFloat(baseAlpha))
      w.strokeColor = c.cgColor
    }
    CATransaction.commit()

    // Pulse and hover never stack: pause the pulse while previewing.
    if isHovered, isControlEnabled {
      stopPulse()
    } else if isActive {
      startPulseIfNeeded()
    } else {
      stopPulse()
    }
  }

  private func startPulseIfNeeded() {
    if pulsing { return }
    // Do not animate off-screen (popover closed, occlusion, or detached view)
    // to avoid keeping WindowServer busy while the app idles in the menu bar.
    if window == nil || window?.isVisible == false || window?.occlusionState.contains(.visible) == false {
      return
    }
    // Respect Reduce Motion: do not mark as pulsing when no animation is installed.
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return }
    pulsing = true

    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 1.0
    scale.toValue = 1.06
    scale.duration = 3.2
    scale.autoreverses = true
    scale.repeatCount = .infinity
    scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

    let glowAnim = CABasicAnimation(keyPath: "shadowRadius")
    glowAnim.fromValue = 22
    glowAnim.toValue = 30
    glowAnim.duration = 3.2
    glowAnim.autoreverses = true
    glowAnim.repeatCount = .infinity
    glowAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 0.95
    opacity.toValue = 1.0
    opacity.duration = 3.2
    opacity.autoreverses = true
    opacity.repeatCount = .infinity

    orbLayer.add(scale, forKey: "pulseScale")
    glowLayer.add(glowAnim, forKey: "pulseGlow")
    orbLayer.add(opacity, forKey: "pulseOpacity")
  }

  private func stopPulse() {
    pulsing = false
    orbLayer.removeAnimation(forKey: "pulseScale")
    orbLayer.removeAnimation(forKey: "pulseOpacity")
    glowLayer.removeAnimation(forKey: "pulseGlow")
  }

  /// Explicit stop for popover close/occlusion; restarts only when visible+active.
  func stopRepetitiveAnimation() { stopPulse() }

  func setWavesVisible(_ visible: Bool) {
    for (i, w) in waveLayers.enumerated() {
      let base = i < waveBaseOpacity.count ? waveBaseOpacity[i] : w.opacity
      w.opacity = visible ? base : 0.15
    }
  }

  // MARK: - On/off button behavior

  func setControlEnabled(_ enabled: Bool) {
    isControlEnabled = enabled
    if !enabled {
      setHovered(false)
      isPressed = false
    }
    applyAppearance(animated: false)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  private func setHovered(_ hovered: Bool) {
    guard hovered != isHovered else { return }
    isHovered = hovered
    applyAppearance(animated: true)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    guard isControlEnabled else { return }
    setHovered(true)
    if !cursorPushed {
      NSCursor.pointingHand.push()
      cursorPushed = true
    }
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    setHovered(false)
    if cursorPushed {
      NSCursor.pop()
      cursorPushed = false
    }
  }

  private func orbHit(point: CGPoint) -> Bool {
    // Hit area is the orb circle (generous: bounding square of the orb).
    let orbSize: CGFloat = 72
    let orbRect = NSRect(
      x: (bounds.width - orbSize) / 2,
      y: (bounds.height - orbSize) / 2 + 8,
      width: orbSize,
      height: orbSize
    )
    return orbRect.insetBy(dx: -6, dy: -6).contains(point)
  }

  override func mouseDown(with event: NSEvent) {
    guard isControlEnabled else { return }
    let point = convert(event.locationInWindow, from: nil)
    guard orbHit(point: point) else { return }
    isPressed = true
    applyAppearance(animated: false)
  }

  override func mouseUp(with event: NSEvent) {
    guard isPressed else { return }
    isPressed = false
    applyAppearance(animated: false)
    guard isControlEnabled else { return }
    let point = convert(event.locationInWindow, from: nil)
    guard orbHit(point: point) else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    onToggle?()
  }

  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool { true }
  override func resignFirstResponder() -> Bool { true }

  override func keyDown(with event: NSEvent) {
    guard isControlEnabled else { super.keyDown(with: event); return }
    if event.keyCode == 49 || event.keyCode == 36 { // Space / Return
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
      onToggle?()
    } else {
      super.keyDown(with: event)
    }
  }

  override func drawFocusRingMask() {
    let orbSize: CGFloat = 72
    let orbRect = NSRect(
      x: (bounds.width - orbSize) / 2,
      y: (bounds.height - orbSize) / 2 + 8,
      width: orbSize,
      height: orbSize
    )
    NSBezierPath(ovalIn: orbRect.insetBy(dx: -4, dy: -4)).fill()
  }

  override var focusRingMaskBounds: NSRect { bounds }

  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityLabel() -> String? { "Ember display filter" }
  override func accessibilityValue() -> Any? { isActive ? "On" : "Off" }
  override func accessibilityHelp() -> String? {
    isActive
      ? "Turns Ember off and restores the original display."
      : "Turns Ember on with the selected warmth and software brightness."
  }
  override func isAccessibilityEnabled() -> Bool { isControlEnabled }
  override func accessibilityPerformPress() -> Bool {
    guard isControlEnabled else { return false }
    onToggle?()
    return true
  }

  private func updateAccessibilityValue() {
    setAccessibilityValue(isActive ? "On" : "Off")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Sync with current active state on appearance; pause when off-screen
    // to avoid keeping the render server busy while the popover is closed.
    if isActive, window != nil, window?.isVisible == true,
      window?.occlusionState.contains(.visible) == true
    {
      startPulseIfNeeded()
    } else if !isActive || window == nil {
      stopPulse()
    } else {
      // Window exists but not visible/occluded → ensure pulse is stopped
      stopPulse()
    }
  }

  override func viewDidHide() {
    super.viewDidHide()
    stopPulse()
    // Never strand a pushed cursor when the popover closes mid-hover.
    setHovered(false)
    if cursorPushed {
      NSCursor.pop()
      cursorPushed = false
    }
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    if isActive { startPulseIfNeeded() }
  }
}

// MARK: - Hero Status Card

@MainActor
final class HeroStatusView: NSView {
  private let bgLayer = CAGradientLayer()
  private let borderLayer = CALayer()
  private let orbView = EmberOrbView(frame: .zero)
  /// Panel on/off action, triggered by the orb button.
  var onOrbToggle: (() -> Void)? {
    didSet { orbView.onToggle = onOrbToggle }
  }

  let titleLabel = NSTextField(labelWithString: "Pure Red is on")
  let detailLabel = NSTextField(wrappingLabelWithString: "Your display is tuned for deep rest and recovery.")
  let metaIcon = NSImageView()
  let metaLabel = NSTextField(labelWithString: "Active on 2 displays")
  let sunsetLabel = NSTextField(labelWithString: "Sunset in 1h 32m")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = EmberMetrics.cardCorner
    layer?.masksToBounds = false
    layer?.borderWidth = 1
    layer?.borderColor = EmberColor.borderHero.cgColor
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.22
    layer?.shadowRadius = 16
    layer?.shadowOffset = CGSize(width: 0, height: 8)

    bgLayer.colors = [
      EmberColor.surfaceHeroFrom.cgColor,
      EmberColor.surfaceHeroTo.cgColor,
    ]
    bgLayer.startPoint = CGPoint(x: 0, y: 1)
    bgLayer.endPoint = CGPoint(x: 1, y: 0)
    bgLayer.cornerRadius = EmberMetrics.cardCorner
    bgLayer.masksToBounds = true
    if let l = layer { l.insertSublayer(bgLayer, at: 0) }

    // Title
    titleLabel.font = EmberFont.heroTitle(size: 15)
    titleLabel.textColor = EmberColor.ember400
    titleLabel.lineBreakMode = .byTruncatingTail

    detailLabel.font = EmberFont.heroDetail()
    detailLabel.textColor = EmberColor.textSecondary
    detailLabel.maximumNumberOfLines = 2
    detailLabel.lineBreakMode = .byWordWrapping
    // preferredMaxLayoutWidth set dynamically in layout() to actual textStack width

    metaIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    metaIcon.contentTintColor = EmberColor.textTertiary

    metaLabel.font = EmberFont.rowCaption()
    metaLabel.textColor = EmberColor.textSecondary
    metaLabel.lineBreakMode = .byTruncatingTail

    sunsetLabel.font = EmberFont.rowCaption()
    sunsetLabel.textColor = EmberColor.textMuted
    sunsetLabel.lineBreakMode = .byTruncatingTail
    sunsetLabel.maximumNumberOfLines = 1
    // sunset time part will be recolored via attributed string in render

    // Layout
    orbView.translatesAutoresizingMaskIntoConstraints = false

    let metaRow = NSStackView(views: [metaIcon, metaLabel])
    metaRow.orientation = .horizontal
    metaRow.spacing = 5
    metaRow.alignment = .centerY

    let metaStack = NSStackView(views: [metaRow, sunsetLabel])
    metaStack.orientation = .vertical
    metaStack.alignment = .leading
    metaStack.spacing = 4

    let textStack = NSStackView(views: [titleLabel, detailLabel, metaStack])
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = 8
    textStack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(textStack)
    addSubview(orbView)

    NSLayoutConstraint.activate([
      textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
      textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
      textStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: orbView.leadingAnchor, constant: -12),

      orbView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      orbView.centerYAnchor.constraint(equalTo: centerYAnchor),
      orbView.widthAnchor.constraint(equalToConstant: 124),
      orbView.heightAnchor.constraint(equalToConstant: 110),

      heightAnchor.constraint(greaterThanOrEqualToConstant: EmberMetrics.heroHeight),
    ])
    textStack.setContentHuggingPriority(.required, for: .vertical)
    textStack.setContentCompressionResistancePriority(.required, for: .vertical)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    bgLayer.frame = bounds
    // Hero: 358 = 390 - 16*2 inset; text leading 16, orb 124, gap 12, trailing 8 => 198 available
    let available = max(0, bounds.width - 16 - 8 - 12 - 124)
    if available > 0 {
      detailLabel.preferredMaxLayoutWidth = available
      metaLabel.preferredMaxLayoutWidth = available
      sunsetLabel.preferredMaxLayoutWidth = available
    }
  }

  func setOrbEnabled(_ enabled: Bool) {
    orbView.setControlEnabled(enabled)
  }

  func render(title: String, detail: String, metaIconName: String?, metaText: String, sunsetText: NSAttributedString?, isActive: Bool, showWaves: Bool) {
    titleLabel.stringValue = title
    titleLabel.textColor = isActive ? EmberColor.ember400 : EmberColor.textPrimary
    detailLabel.stringValue = detail
    metaLabel.stringValue = metaText
    if let name = metaIconName, let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
      metaIcon.image = img
      metaIcon.isHidden = false
    } else {
      metaIcon.isHidden = true
    }
    if let attr = sunsetText {
      sunsetLabel.attributedStringValue = attr
      sunsetLabel.isHidden = false
    } else {
      sunsetLabel.isHidden = true
    }

    bgLayer.colors = isActive
      ? [EmberColor.surfaceHeroActiveFrom.cgColor, EmberColor.surfaceHeroActiveTo.cgColor]
      : [EmberColor.surfaceHeroFrom.cgColor, EmberColor.surfaceHeroTo.cgColor]
    layer?.borderColor = isActive ? EmberColor.borderHero.cgColor : EmberColor.borderSubtle.cgColor
    orbView.setActive(isActive, animated: true)
    // showWaves is honored: waves/extra glow only when requested and active.
    orbView.isHidden = false
    orbView.setWavesVisible(showWaves && isActive)
    needsDisplay = true
  }

  func setSunsetAttributed(sunsetIn: String?) {
    guard let str = sunsetIn else {
      sunsetLabel.isHidden = true
      return
    }
    // "Sunset in 1h 32m" -> color time part
    let full = "Sunset in \(str)"
    let attr = NSMutableAttributedString(string: full)
    attr.addAttribute(.foregroundColor, value: EmberColor.textSecondary, range: NSRange(location: 0, length: attr.length))
    let timeRange = (full as NSString).range(of: str)
    attr.addAttribute(.foregroundColor, value: EmberColor.ember400, range: timeRange)
    sunsetLabel.attributedStringValue = attr
    sunsetLabel.isHidden = false
  }
}