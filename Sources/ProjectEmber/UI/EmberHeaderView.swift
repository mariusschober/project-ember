import AppKit

@MainActor
final class EmberPowerButton: NSButton {
  private let bgLayer = CALayer()
  private let iconView = NSImageView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = false
    isBordered = false
    bezelStyle = .regularSquare
    title = ""
    imagePosition = .imageOnly

    bgLayer.cornerRadius = 16
    bgLayer.masksToBounds = true
    bgLayer.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
    bgLayer.borderWidth = 1
    bgLayer.borderColor = EmberColor.borderSubtle.cgColor
    layer?.addSublayer(bgLayer)

    iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    iconView.contentTintColor = EmberColor.textTertiary
    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)
    iconView.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Power")
    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      widthAnchor.constraint(equalToConstant: 32),
      heightAnchor.constraint(equalToConstant: 32),
    ])

    wantsLayer = true
    // hover tracking
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(area)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    bgLayer.frame = bounds
    bgLayer.cornerRadius = bounds.height/2
  }

  var isActiveState = false {
    didSet { updateAppearance() }
  }

  private func updateAppearance() {
    if isActiveState {
      bgLayer.backgroundColor = NSColor(calibratedRed: 0.32, green: 0.16, blue: 0.13, alpha: 1.0).cgColor
      bgLayer.borderColor = EmberColor.ember500.withAlphaComponent(0.28).cgColor
      bgLayer.shadowColor = EmberColor.ember500.cgColor
      bgLayer.shadowOpacity = 0.32
      bgLayer.shadowRadius = 8
      bgLayer.shadowOffset = .zero
      iconView.contentTintColor = EmberColor.ember400
    } else {
      bgLayer.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
      bgLayer.borderColor = EmberColor.borderSubtle.cgColor
      bgLayer.shadowOpacity = 0
      iconView.contentTintColor = EmberColor.textTertiary
    }
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    bgLayer.borderColor = EmberColor.textMuted.withAlphaComponent(0.18).cgColor
  }
  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    updateAppearance()
  }
}

@MainActor
final class EmberHeaderView: NSView {
  let iconView = NSImageView()
  let titleLabel = NSTextField(labelWithString: "EMBER")
  let subtitleLabel = NSTextField(labelWithString: "Light in harmony with your body.")
  let powerButton = EmberPowerButton(frame: .zero)
  let stateLabel = NSTextField(labelWithString: "OFF")
  let betaLabel = NSTextField(labelWithString: "BETA") // kept for compatibility, hidden

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true

    // Ember orb — red-dot sun, matches app icon / hero orb
    iconView.image = EmberDotIcon.headerImage()
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.wantsLayer = false
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.widthAnchor.constraint(equalToConstant: 28).isActive = true
    iconView.heightAnchor.constraint(equalToConstant: 28).isActive = true

    titleLabel.font = EmberFont.headerTitle()
    titleLabel.textColor = EmberColor.textPrimary
    // tracking
    let attrTitle = NSMutableAttributedString(string: "EMBER")
    attrTitle.addAttribute(.kern, value: 3.2, range: NSRange(location: 0, length: 5))
    titleLabel.attributedStringValue = attrTitle

    subtitleLabel.font = EmberFont.headerSubtitle()
    subtitleLabel.textColor = EmberColor.textSecondary
    subtitleLabel.lineBreakMode = .byTruncatingTail

    let textStack = NSStackView(views: [titleLabel, subtitleLabel])
    textStack.orientation = .vertical
    textStack.spacing = 1
    textStack.alignment = .leading

    betaLabel.font = NSFont.systemFont(ofSize: 9, weight: .bold)
    betaLabel.textColor = EmberColor.ember400
    betaLabel.alphaValue = 0.95

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    powerButton.translatesAutoresizingMaskIntoConstraints = false

    let row = NSStackView(views: [iconView, textStack, spacer, stateLabel, powerButton])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 9
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)

    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
      heightAnchor.constraint(greaterThanOrEqualToConstant: EmberMetrics.headerHeight),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func setBetaHidden(_ hidden: Bool) {
    betaLabel.isHidden = hidden
  }
  func setState(isActive: Bool) {
    let title = isActive ? "ON" : "OFF"
    let attr = NSMutableAttributedString(string: title)
    attr.addAttribute(.kern, value: 0.8, range: NSRange(location: 0, length: title.count))
    attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 10, weight: .semibold), range: NSRange(location: 0, length: title.count))
    attr.addAttribute(.foregroundColor, value: isActive ? EmberColor.ember400 : EmberColor.textTertiary, range: NSRange(location: 0, length: title.count))
    stateLabel.attributedStringValue = attr
  }
}

@MainActor
final class EmberFooterBarView: NSView {
  let heartView = NSImageView()
  let textLabel = NSTextField(labelWithString: "")
  let betaBadge = NSTextField(labelWithString: "BETA")
  let versionLabel = NSTextField(labelWithString: "v1.0.0")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0).cgColor
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.white.withAlphaComponent(0.04).cgColor

    heartView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
    heartView.contentTintColor = NSColor(calibratedRed: 0.68, green: 0.22, blue: 0.18, alpha: 1.0)
    heartView.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)
    heartView.translatesAutoresizingMaskIntoConstraints = false
    heartView.widthAnchor.constraint(equalToConstant: 14).isActive = true
    heartView.heightAnchor.constraint(equalToConstant: 14).isActive = true

    textLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
    textLabel.textColor = EmberColor.textSecondary

    betaBadge.font = NSFont.systemFont(ofSize: 9, weight: .bold)
    betaBadge.textColor = EmberColor.ember400
    betaBadge.alphaValue = 0.95
    betaBadge.wantsLayer = true
    betaBadge.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
    betaBadge.layer?.cornerRadius = 6
    betaBadge.layer?.masksToBounds = true
    betaBadge.translatesAutoresizingMaskIntoConstraints = false
    versionLabel.font = NSFont.systemFont(ofSize: 9, weight: .medium)
    versionLabel.textColor = EmberColor.textTertiary
    versionLabel.wantsLayer = true
    versionLabel.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
    versionLabel.layer?.cornerRadius = 6
    versionLabel.layer?.masksToBounds = true

    let left = NSStackView(views: [heartView, textLabel])
    left.orientation = .horizontal
    left.spacing = 6
    left.alignment = .centerY

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let betaVersionStack = NSStackView(views: [betaBadge, versionLabel])
    betaVersionStack.orientation = .horizontal
    betaVersionStack.spacing = 6
    betaVersionStack.alignment = .centerY
    let container = NSStackView(views: [left, spacer, betaVersionStack])
    container.orientation = .horizontal
    container.alignment = .centerY
    container.spacing = 8
    container.translatesAutoresizingMaskIntoConstraints = false
    addSubview(container)

    NSLayoutConstraint.activate([
      container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      container.topAnchor.constraint(equalTo: topAnchor),
      container.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(equalToConstant: EmberMetrics.footerBarHeight),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func setText(circadianPrefix: String = "Designed for your ", circadianAccent: String = "circadian health", version: String = "v1.0.0") {
    let full = circadianPrefix + circadianAccent
    let attr = NSMutableAttributedString(string: full)
    attr.addAttribute(.foregroundColor, value: EmberColor.textSecondary, range: NSRange(location: 0, length: full.count))
    attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 11, weight: .regular), range: NSRange(location: 0, length: full.count))
    let range = (full as NSString).range(of: circadianAccent)
    attr.addAttribute(.foregroundColor, value: EmberColor.ember400, range: range)
    attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 11, weight: .medium), range: range)
    textLabel.attributedStringValue = attr
    versionLabel.stringValue = "  \(version)  "
  }
}

@MainActor
final class EmberFooterActionsView: NSView {
  let diagnosticsButton = NSButton(title: "Diagnostics", target: nil, action: nil)
  let quitButton = NSButton(title: "Quit", target: nil, action: nil)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true

    // Pill styling — 30h, 15r, centered content
    func stylePill(_ btn: NSButton, title: String, color: NSColor, symbol: String?) {
      btn.bezelStyle = .inline
      btn.isBordered = false
      btn.wantsLayer = true
      btn.layer?.cornerRadius = 15
      btn.layer?.masksToBounds = true
      btn.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor
      btn.layer?.borderWidth = 1
      btn.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
      btn.font = EmberFont.footerAction()
      btn.contentTintColor = color
      if let sym = symbol, let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        btn.image = img.withSymbolConfiguration(cfg)
        btn.imagePosition = .imageLeading
        btn.imageScaling = .scaleProportionallyDown
      }
      // Centered title with paragraph style
      let style = NSMutableParagraphStyle()
      style.alignment = .center
      btn.attributedTitle = NSAttributedString(string: title, attributes: [
        .font: EmberFont.footerAction(),
        .foregroundColor: color,
        .paragraphStyle: style,
      ])
      btn.translatesAutoresizingMaskIntoConstraints = false
      btn.heightAnchor.constraint(equalToConstant: 30).isActive = true
      // Intrinsic width with padding
      let pad: CGFloat = (symbol == nil) ? 22 : 28
      btn.widthAnchor.constraint(greaterThanOrEqualToConstant: pad + (title as NSString).size(withAttributes: [.font: EmberFont.footerAction()]).width).isActive = true
      // Center content
      (btn.cell as? NSButtonCell)?.isHighlighted = false
      btn.setButtonType(.momentaryPushIn)
      btn.controlSize = .regular
    }

    stylePill(diagnosticsButton, title: "Diagnostics", color: EmberColor.textSecondary, symbol: nil)
    stylePill(quitButton, title: "Quit", color: EmberColor.textPrimary, symbol: nil)
    // Keep quit ember accent for text but pill background same
    quitButton.contentTintColor = EmberColor.textPrimary
    // Override quit title to ember for emphasis? Keep primary for readability, but add ember tint via layer border
    quitButton.layer?.borderColor = EmberColor.ember500.withAlphaComponent(0.14).cgColor

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [diagnosticsButton, spacer, quitButton])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
      row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
      heightAnchor.constraint(equalToConstant: 32),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
}