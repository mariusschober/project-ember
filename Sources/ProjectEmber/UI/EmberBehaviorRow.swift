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
    iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true
    iconView.heightAnchor.constraint(equalToConstant: 20).isActive = true
    iconView.imageScaling = .scaleProportionallyDown
    iconView.image = NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: "Menu bar click")

    titleLabel.font = EmberFont.rowTitle()
    titleLabel.textColor = EmberColor.textPrimary
    detailLabel.font = EmberFont.rowDetail()
    detailLabel.textColor = EmberColor.textSecondary
    detailLabel.maximumNumberOfLines = 2
    detailLabel.lineBreakMode = .byWordWrapping

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

    addSubview(iconView)
    addSubview(vertical)
    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      iconView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      vertical.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
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
