import AppKit

/// One-line first-launch explanation, shown once above the hero.
///
/// The reviewer's first ten seconds used to be an unlabelled grey dot in the
/// menu bar with no hint that the *orb* is the on/off control (audit M9). This
/// card names the product, the mechanism, and the affordance in one sentence,
/// then never appears again.
@MainActor
final class EmberFirstRunHintView: NSView {
  private let iconView = NSImageView()
  private let label = NSTextField(wrappingLabelWithString: "")
  private static let inset: CGFloat = 12
  /// Deterministic wrap width: content column minus card insets, icon, and gap.
  private static let textWidth: CGFloat =
    EmberMetrics.contentWidth - (inset * 2) - EmberMetrics.rowIconWidth
    - EmberMetrics.rowIconTextGap
  static let message =
    "Ember warms and dims your display after dark — click the orb to turn it on."

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = EmberMetrics.cardCorner
    layer?.masksToBounds = true
    layer?.backgroundColor = EmberColor.controlFill.cgColor
    layer?.borderWidth = 1
    layer?.borderColor = EmberColor.borderHero.cgColor

    iconView.image = NSImage(
      systemSymbolName: "sparkles", accessibilityDescription: nil)
    iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    iconView.contentTintColor = EmberColor.ember400
    iconView.imageScaling = .scaleProportionallyDown
    iconView.setAccessibilityElement(false)
    iconView.translatesAutoresizingMaskIntoConstraints = false

    label.stringValue = Self.message
    label.font = EmberFont.rowDetail()
    label.textColor = EmberColor.textPrimary
    label.maximumNumberOfLines = EmberMetrics.detailMaxLines
    label.lineBreakMode = .byWordWrapping
    label.preferredMaxLayoutWidth = Self.textWidth
    label.setAccessibilityLabel(Self.message)
    label.setAccessibilityRole(.staticText)
    // Manual constraints (not an NSStackView), so the label must opt out of the
    // autoresizing mask or its frame-derived constraints win and the text
    // collapses to nothing.
    label.translatesAutoresizingMaskIntoConstraints = false

    addSubview(iconView)
    addSubview(label)
    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
      iconView.centerYAnchor.constraint(equalTo: label.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: EmberMetrics.rowIconWidth),
      iconView.heightAnchor.constraint(equalToConstant: EmberMetrics.rowIconWidth),

      label.leadingAnchor.constraint(
        equalTo: iconView.trailingAnchor, constant: EmberMetrics.rowIconTextGap),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
      label.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
}
