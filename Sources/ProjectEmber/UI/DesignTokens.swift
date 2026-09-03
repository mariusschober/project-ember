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

  // Text — all below 18pt meet ≥4.5:1 on card surface in composited state.
  // Hierarchy retained with brighter muted/tertiary than 0.3.0.
  static let textPrimary = NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.93, alpha: 1.0)
  static let textSecondary = NSColor(calibratedRed: 0.82, green: 0.79, blue: 0.77, alpha: 1.0)
  static let textTertiary = NSColor(calibratedRed: 0.70, green: 0.68, blue: 0.67, alpha: 1.0)
  static let textMuted = NSColor(calibratedRed: 0.62, green: 0.60, blue: 0.59, alpha: 1.0)
  // Opaque fallback when Reduce Transparency is enabled (replaces HUD/vibrancy).
  static let surfaceOpaque = NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.12, alpha: 1.0)

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
  static let rowHeight: CGFloat = 56
  // Shared row grid: every row type (toggle, behavior, slider icon) aligns
  // icons and trailing controls to these insets so columns line up.
  static let rowLeadingInset: CGFloat = 14
  static let rowTrailingInset: CGFloat = 14
  static let rowIconWidth: CGFloat = 20
  static let rowIconTextGap: CGFloat = 10
  static let rowMinHeight: CGFloat = 56
  static let rowTopPadding: CGFloat = 10
  static let rowBottomPadding: CGFloat = 10
  // Pill preset geometry: outer breathing room from the container edge plus
  // internal relief around the label so the highlight never hugs text.
  static let pillHeight: CGFloat = 42
  static let pillStackInset: CGFloat = 5
  static let pillIndicatorHInset: CGFloat = 3
  static let pillIndicatorVInset: CGFloat = 3
  static let sliderThumb: CGFloat = 22
  static let sliderTrackHeight: CGFloat = 4
  static let sliderEndInset: CGFloat = 14 // thumbSize/2 + 3: keeps thumbs fully visible at 0%/100%
  // Deterministic wrapping widths. These MUST be static constants, never
  // derived from bounds at layout time: deriving wrap widths from bounds
  // creates a width↔wrap feedback loop (width sets wrap, wrap sets intrinsic
  // height, height re-resolves width) that never converges — rows stagger,
  // icons stretch, and the window grows past 390pt.
  // Toggle-row text = 390 − 32 (content) − 14 − 20 − 10 − 12 − 44 − 14.
  static let rowTextWidth: CGFloat = 244
  // Hero text = 390 − 32 (content) − 16 (leading) − 12 (gap) − 124 (orb) − 8.
  static let heroTextWidth: CGFloat = 198
  static let stackSpacing: CGFloat = 10
  static let heroHeight: CGFloat = 128
  static let headerHeight: CGFloat = 40
  static let footerBarHeight: CGFloat = 36
}

extension NSColor {
  func withAlpha(_ a: CGFloat) -> NSColor { withAlphaComponent(a) }
}
