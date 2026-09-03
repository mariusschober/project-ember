import AppKit

@MainActor
final class EmberHeaderView: NSView {
  let iconView = NSImageView()
  let titleLabel = NSTextField(labelWithString: "EMBER")
  // Single-line tagline sized to the 321pt header budget (390 − 32 content
  // − 28 icon − 9 gap). NOTE for owner review: shortened from "Reduces
  // short-wavelength display output for evening use." — the longer string's
  // uncapped truncating intrinsic width stretched the whole window past 390pt.
  let subtitleLabel = NSTextField(labelWithString: "Reduces short-wavelength light for evening use.")
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

    // The hero orb is the panel's on/off control; the header is static branding.
    let row = NSStackView(views: [iconView, textStack, spacer])
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
}

@MainActor
final class EmberFooterBarView: NSView {
  // NOTE: no heart icon — the full claim sentence plus badge already fill the
  // 390pt footer budget (366pt usable); a 14pt decoration pushed fitting to
  // 414pt and grew the whole window.
  let prefixLabel = NSTextField(labelWithString: "Designed by\u{00A0}")
  let authorButton = NSButton(title: "Marius Schober", target: nil, action: nil)
  let suffixLabel = NSTextField(labelWithString: "\u{00A0}for circadian-aware evenings")
  // Single badge ("BETA · v0.4.0"): two badges cost ~73pt vs ~66pt.
  let betaBadge = NSTextField(labelWithString: "BETA · v0.4.0")
  private static let authorURL = URL(string: "https://mariusschober.com/")!

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0).cgColor
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.white.withAlphaComponent(0.04).cgColor

    // 9.5pt attribution text: larger sizes summed past the 366pt footer
    // budget and grew the whole window (see subtitle note).
    prefixLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
    prefixLabel.textColor = EmberColor.textSecondary
    suffixLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .regular)
    suffixLabel.textColor = EmberColor.textSecondary
    for label in [prefixLabel, suffixLabel] {
      label.lineBreakMode = .byTruncatingTail
    }

    authorButton.bezelStyle = .inline
    authorButton.isBordered = false
    authorButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    authorButton.contentTintColor = EmberColor.ember400
    authorButton.target = self
    authorButton.action = #selector(openAuthorLink)
    authorButton.toolTip = "Open mariusschober.com"
    authorButton.setAccessibilityLabel("Marius Schober")
    authorButton.setAccessibilityHelp("Opens the author's website.")
    authorButton.setAccessibilityRole(.link)

    betaBadge.font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
    betaBadge.textColor = EmberColor.ember400
    betaBadge.alphaValue = 0.95
    betaBadge.wantsLayer = true
    betaBadge.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
    betaBadge.layer?.cornerRadius = 6
    betaBadge.layer?.masksToBounds = true
    betaBadge.translatesAutoresizingMaskIntoConstraints = false

    let left = NSStackView(views: [prefixLabel, authorButton, suffixLabel])
    left.orientation = .horizontal
    left.spacing = 2
    left.alignment = .centerY

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let container = NSStackView(views: [left, spacer, betaBadge])
    container.orientation = .horizontal
    container.alignment = .centerY
    container.spacing = 4
    container.translatesAutoresizingMaskIntoConstraints = false
    addSubview(container)

    NSLayoutConstraint.activate([
      container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      container.topAnchor.constraint(equalTo: topAnchor),
      container.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(equalToConstant: EmberMetrics.footerBarHeight),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func setText(version: String = AppVersionDisplay.fallback) {
    betaBadge.stringValue = " BETA · \(version) "
  }

  private var authorCursorPushed = false

  override func layout() {
    super.layout()
    // Keep the author-link hover area glued to the button frame.
    updateTrackingAreas()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    // Underline the author link on hover only; calm plain text otherwise.
    for area in trackingAreas where (area.userInfo?["authorLink"] as? Bool) == true {
      removeTrackingArea(area)
    }
    addTrackingArea(NSTrackingArea(
      rect: authorButton.frame,
      options: [.mouseEnteredAndExited, .activeInKeyWindow],
      owner: self, userInfo: ["authorLink": true]))
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    setAuthorUnderline(true)
    if !authorCursorPushed {
      NSCursor.pointingHand.push()
      authorCursorPushed = true
    }
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    setAuthorUnderline(false)
    if authorCursorPushed {
      NSCursor.pop()
      authorCursorPushed = false
    }
  }

  private func setAuthorUnderline(_ underline: Bool) {
    let title = authorButton.title
    let attr = NSMutableAttributedString(string: title)
    attr.addAttribute(
      .font, value: NSFont.systemFont(ofSize: 11, weight: .medium),
      range: NSRange(location: 0, length: attr.length))
    attr.addAttribute(
      .foregroundColor, value: EmberColor.ember400,
      range: NSRange(location: 0, length: attr.length))
    if underline {
      attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
        range: NSRange(location: 0, length: attr.length))
    }
    authorButton.attributedTitle = attr
  }

  @objc private func openAuthorLink() {
    NSWorkspace.shared.open(Self.authorURL)
  }
}

/// Version fallback without importing EmberCore into this UI file's contract.
private enum AppVersionDisplay {
  static let fallback = "v0.4.0"
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