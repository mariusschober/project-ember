import AppKit
import EmberCore

@MainActor
final class EmberBehaviorRowView: NSView {
  let iconView = NSImageView()
  let titleLabel = NSTextField(labelWithString: "Menu bar click")
  let detailLabel = NSTextField(wrappingLabelWithString: "Right-click always opens controls.")
  private let openButton = NSButton(radioButtonWithTitle: "Open Controls", target: nil, action: nil)
  private let toggleButton = NSButton(radioButtonWithTitle: "Toggle Ember", target: nil, action: nil)
  var onSelect: ((MenuBarPrimaryAction) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    iconView.contentTintColor = EmberColor.textTertiary
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyDown
    iconView.image = NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: "Menu bar click")
    // Fixed-size box (see EmberToggleRowView): the glyph letterboxes inside
    // instead of fighting aspect constraints.
    let iconBox = NSView()
    iconBox.translatesAutoresizingMaskIntoConstraints = false
    iconBox.widthAnchor.constraint(equalToConstant: EmberMetrics.rowIconWidth).isActive = true
    iconBox.heightAnchor.constraint(equalToConstant: EmberMetrics.rowIconWidth).isActive = true
    iconBox.addSubview(iconView)
    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
      iconView.widthAnchor.constraint(lessThanOrEqualToConstant: EmberMetrics.rowIconWidth),
      iconView.heightAnchor.constraint(lessThanOrEqualToConstant: EmberMetrics.rowIconWidth),
    ])

    titleLabel.font = EmberFont.rowTitle()
    titleLabel.textColor = EmberColor.textPrimary
    titleLabel.setContentHuggingPriority(.required, for: .vertical)
    detailLabel.font = EmberFont.rowDetail()
    detailLabel.textColor = EmberColor.textSecondary
    detailLabel.maximumNumberOfLines = 2
    detailLabel.preferredMaxLayoutWidth = EmberMetrics.rowTextWidth + 40
    detailLabel.lineBreakMode = .byWordWrapping
    detailLabel.setContentHuggingPriority(.required, for: .vertical)

    openButton.font = .systemFont(ofSize: 11, weight: .regular)
    openButton.target = self
    openButton.action = #selector(chooseOpen)
    toggleButton.font = .systemFont(ofSize: 11, weight: .regular)
    toggleButton.target = self
    toggleButton.action = #selector(chooseToggle)

    let textStack = NSStackView(views: [titleLabel, detailLabel])
    textStack.orientation = .vertical
    textStack.spacing = 2
    textStack.alignment = .leading
    textStack.translatesAutoresizingMaskIntoConstraints = false

    let options = NSStackView(views: [openButton, toggleButton])
    options.orientation = .horizontal
    options.spacing = 12
    options.alignment = .centerY
    options.translatesAutoresizingMaskIntoConstraints = false

    let vertical = NSStackView(views: [textStack, options])
    vertical.orientation = .vertical
    vertical.spacing = 6
    vertical.alignment = .leading
    vertical.translatesAutoresizingMaskIntoConstraints = false

    addSubview(iconBox)
    addSubview(vertical)
    NSLayoutConstraint.activate([
      iconBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: EmberMetrics.rowLeadingInset),
      iconBox.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      vertical.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: EmberMetrics.rowIconTextGap),
      vertical.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      vertical.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      vertical.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func render(_ action: MenuBarPrimaryAction) {
    openButton.state = action == .openControls ? .on : .off
    toggleButton.state = action == .toggleEmber ? .on : .off
  }

  func setAccessibility() {
    setAccessibilityRole(.group)
    setAccessibilityLabel("Menu bar click behavior")
    openButton.setAccessibilityLabel("Open Controls")
    toggleButton.setAccessibilityLabel("Toggle Ember")
  }

  @objc private func chooseOpen() { onSelect?(.openControls) }
  @objc private func chooseToggle() { onSelect?(.toggleEmber) }
}
