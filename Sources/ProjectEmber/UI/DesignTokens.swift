import AppKit

// MARK: - Ember Design Tokens
// Warm, dusk-inspired palette aligned to circadian health. No blue light in UI itself.
// All colors defined in sRGB, dark-only. Light appearance never used (forced darkAqua).

enum EmberColor {
  // Brand ember
  static let ember500 = NSColor(calibratedRed: 1.00, green: 0.29, blue: 0.18, alpha: 1.0) // #FF4A2E
  static let ember400 = NSColor(calibratedRed: 1.00, green: 0.44, blue: 0.32, alpha: 1.0)
  static let ember600 = NSColor(calibratedRed: 0.78, green: 0.20, blue: 0.09, alpha: 1.0) // #C73217
  static let ember700 = NSColor(calibratedRed: 0.55, green: 0.15, blue: 0.07, alpha: 1.0)
  static let emberGlow = NSColor(calibratedRed: 1.00, green: 0.24, blue: 0.13, alpha: 0.40)

  // Ink / surfaces
  static let ink900 = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1.0) // #171719
  static let ink800 = NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)
  static let surfacePanel = NSColor(calibratedRed: 0.15, green: 0.14, blue: 0.15, alpha: 1.0)
  static let surfaceCard = NSColor(calibratedRed: 0.19, green: 0.19, blue: 0.20, alpha: 1.0) // #303032
  static let surfaceCardElevated = NSColor(calibratedRed: 0.22, green: 0.21, blue: 0.21, alpha: 1.0)
  static let surfaceHeroFrom = NSColor(calibratedRed: 0.28, green: 0.16, blue: 0.14, alpha: 1.0)
  static let surfaceHeroTo = NSColor(calibratedRed: 0.20, green: 0.13, blue: 0.12, alpha: 1.0)
  static let surfaceHeroActiveFrom = NSColor(calibratedRed: 0.36, green: 0.18, blue: 0.14, alpha: 1.0)
  static let surfaceHeroActiveTo = NSColor(calibratedRed: 0.24, green: 0.13, blue: 0.11, alpha: 1.0)

  // Text
  static let textPrimary = NSColor(calibratedRed: 0.95, green: 0.93, blue: 0.92, alpha: 1.0)
  static let textSecondary = NSColor(calibratedRed: 0.71, green: 0.68, blue: 0.66, alpha: 1.0) // #B5ADA9
  static let textTertiary = NSColor(calibratedRed: 0.52, green: 0.50, blue: 0.50, alpha: 1.0)
  static let textMuted = NSColor(calibratedRed: 0.43, green: 0.41, blue: 0.40, alpha: 1.0)

  // Borders / dividers
  static let borderSubtle = NSColor(calibratedWhite: 1.0, alpha: 0.07)
  static let borderCard = NSColor(calibratedWhite: 1.0, alpha: 0.08)
  static let borderHero = NSColor(calibratedRed: 1.00, green: 0.30, blue: 0.18, alpha: 0.14)
  static let divider = NSColor(calibratedWhite: 1.0, alpha: 0.06)

  // Functional
  static let success = NSColor(calibratedRed: 0.26, green: 0.78, blue: 0.38, alpha: 1.0)
  static let warning = NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.24, alpha: 1.0)
  static let error = NSColor(calibratedRed: 1.00, green: 0.27, blue: 0.23, alpha: 1.0)

  static let sliderTrackWarmNeutral = NSColor(calibratedRed: 0.45, green: 0.43, blue: 0.42, alpha: 1.0)
  static let sliderTrackWarmMid = NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.18, alpha: 1.0)
  static let sliderTrackDim = NSColor(calibratedWhite: 0.30, alpha: 1.0)
  static let sliderTrackBright = NSColor(calibratedRed: 0.90, green: 0.25, blue: 0.18, alpha: 1.0)
}

enum EmberFont {
  static func headerTitle() -> NSFont { .systemFont(ofSize: 18, weight: .bold) }
  static func headerSubtitle() -> NSFont { .systemFont(ofSize: 11, weight: .medium) }
  static func heroTitle(size: CGFloat = 15) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }
  static func heroDetail() -> NSFont { .systemFont(ofSize: 11.5, weight: .regular) }
  static func meta() -> NSFont { .systemFont(ofSize: 11, weight: .regular) }
  static func sectionCAP() -> NSFont { .systemFont(ofSize: 9.5, weight: .bold) }
  static func pill() -> NSFont { .systemFont(ofSize: 12.5, weight: .medium) }
  static func pillSelected() -> NSFont { .systemFont(ofSize: 12.5, weight: .semibold) }
  static func sliderTitle() -> NSFont { .systemFont(ofSize: 10.5, weight: .medium) }
  static func sliderValue() -> NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .semibold) }
  static func rowTitle() -> NSFont { .systemFont(ofSize: 12.5, weight: .semibold) }
  static func rowDetail() -> NSFont { .systemFont(ofSize: 10.5, weight: .regular) }
  static func rowCaption() -> NSFont { .systemFont(ofSize: 9.5, weight: .medium) }
  static func footerAction() -> NSFont { .systemFont(ofSize: 11, weight: .medium) }
}

enum EmberMetrics {
  static let popoverWidth: CGFloat = 390
  static let contentHInset: CGFloat = 16
  static let cardCorner: CGFloat = 14
  static let pillCorner: CGFloat = 18
  static let rowHeight: CGFloat = 64
  static let sliderThumb: CGFloat = 22
  static let sliderTrackHeight: CGFloat = 4
  static let heroHeight: CGFloat = 148
  static let headerHeight: CGFloat = 44
  static let footerBarHeight: CGFloat = 36
}

extension NSColor {
  func withAlpha(_ a: CGFloat) -> NSColor { withAlphaComponent(a) }
}
