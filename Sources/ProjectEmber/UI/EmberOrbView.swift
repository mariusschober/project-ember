import AppKit

@MainActor
final class EmberOrbView: NSView {
  private let orbLayer = CALayer()
  private let glowLayer = CALayer()
  private let highlightLayer = CALayer()
  private var waveLayers: [CAShapeLayer] = []
  private var isActive = false
  private var pulsing = false

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

    // Inner highlight
    highlightLayer.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
    highlightLayer.cornerRadius = 18
    highlightLayer.masksToBounds = true

    // Waves at bottom - three gentle sine-like curves (inactive grey)
    for i in 0..<3 {
      let wave = CAShapeLayer()
      wave.fillColor = NSColor.clear.cgColor
      wave.strokeColor = NSColor(calibratedWhite: 0.45, alpha: 0.06).cgColor
      wave.lineWidth = 0.9
      wave.lineCap = .round
      wave.opacity = 0.7 - Float(i) * 0.15
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
      x: orbRect.minX + 14,
      y: orbRect.maxY - 28,
      width: 28,
      height: 18
    )
    highlightLayer.cornerRadius = 9

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

  func setActive(_ active: Bool, animated: Bool) {
    // Always update visual, even if isActive already equals active — ensures initial off state is grey not orange
    isActive = active
    needsLayout = true

    if active {
      glowLayer.opacity = 1
      orbLayer.opacity = 1
      glowLayer.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.24, blue: 0.13, alpha: 0.28).cgColor
      if let grad = orbLayer.value(forKey: "gradient") as? CAGradientLayer {
        grad.colors = [
          NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.22, alpha: 1.0).cgColor,
          NSColor(calibratedRed: 1.0, green: 0.22, blue: 0.12, alpha: 1.0).cgColor,
          NSColor(calibratedRed: 0.78, green: 0.14, blue: 0.09, alpha: 1.0).cgColor,
        ]
      }
      startPulseIfNeeded()
    } else {
      glowLayer.opacity = 0.22
      orbLayer.opacity = 0.85
      glowLayer.backgroundColor = NSColor(calibratedWhite: 0.35, alpha: 0.10).cgColor
      if let grad = orbLayer.value(forKey: "gradient") as? CAGradientLayer {
        grad.colors = [
          NSColor(calibratedWhite: 0.52, alpha: 1.0).cgColor,
          NSColor(calibratedWhite: 0.42, alpha: 1.0).cgColor,
          NSColor(calibratedWhite: 0.32, alpha: 1.0).cgColor,
        ]
      }
      stopPulse()
    }
    let alpha: CGFloat = active ? 0.22 : 0.06
    for (i, w) in waveLayers.enumerated() {
      let c: NSColor = active ? NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.22, alpha: alpha - CGFloat(i)*0.03) : NSColor(calibratedWhite: 0.45, alpha: alpha)
      w.strokeColor = c.cgColor
    }
  }

  private func startPulseIfNeeded() {
    if pulsing { return }
    // Do not animate off-screen (popover closed, occlusion, or detached view)
    // to avoid keeping WindowServer busy while the app idles in the menu bar.
    if window == nil || window?.isVisible == false || window?.occlusionState.contains(.visible) == false {
      return
    }
    pulsing = true
    // Respect reduce motion
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return }

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
    orbView.isHidden = !showWaves // keep hidden for off? spec shows sun even dim - but we show dimmed
    // Always show orb per screenshot, but dim when off
    orbView.isHidden = false
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