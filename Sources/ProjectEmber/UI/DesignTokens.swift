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
  // Active hero top-left stop. Darkened from 0.36/0.18/0.14: ember400 on the
  // old stop measured 4.12:1, and the 15 pt semibold title is not "large text"
  // under WCAG, so it needs 4.5:1. New stop gives 4.78:1 and keeps the ember
  // accent instead of falling back to textPrimary (audit M2).
  static let surfaceHeroActiveFrom = NSColor(calibratedRed: 0.30, green: 0.15, blue: 0.12, alpha: 1.0)
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
  // Component outlines. WCAG 1.4.11 wants >=3:1 against the adjacent surface;
  // 0.08 white composited over the card measured 1.28:1 (audit M4). 0.38 white
  // composites to ~0.46 over the panel (3.5:1) and ~0.50 over the card (3.3:1):
  // a visible edge that still reads as a hairline, not a highlight.
  static let borderCard = NSColor(calibratedWhite: 1.0, alpha: 0.38)
  static let borderControl = NSColor(calibratedWhite: 1.0, alpha: 0.38)
  static let borderHero = NSColor(calibratedRed: 1.00, green: 0.30, blue: 0.18, alpha: 0.14)
  static let divider = NSColor(calibratedWhite: 1.0, alpha: 0.06)

  // Structural greys for control travel/tracks. Audit M4 measured the unfilled
  // slider track at 1.41:1 and the off switch at 1.64:1 against their surface.
  static let controlBoundary = NSColor(calibratedWhite: 0.42, alpha: 1.0)
  /// Segmented-control and switch bodies: dark fill, bright outline so the
  /// component edge — not the whole surface — carries the contrast.
  static let controlFill = NSColor(calibratedWhite: 0.20, alpha: 1.0)

  // Functional
  static let success = NSColor(calibratedRed: 0.26, green: 0.78, blue: 0.38, alpha: 1.0)
  static let warning = NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.24, alpha: 1.0)
  // Lightened from 1.00/0.27/0.23: the 9.5 pt error caption measured 3.84:1 on
  // surfaceCard (audit M3); this value measures 4.9:1 and still reads as error.
  static let error = NSColor(calibratedRed: 1.00, green: 0.44, blue: 0.39, alpha: 1.0)

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
  /// Width of the content column. Constant on purpose: the panel width is
  /// pinned at 390 and the scroll view's document is constrained to this
  /// constant, so no wrap width is ever derived from `bounds` (see the comment
  /// on the wrap-width constants below).
  static let contentWidth: CGFloat = popoverWidth - (contentHInset * 2)
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
  /// Minimum interactive height for a slider. The thumb is drawn 22 pt and the
  /// view's intrinsic height is 16 pt, so 3 pt of the visible thumb at top and
  /// bottom belonged to the parent and dropped clicks (audit M12).
  static let sliderHitHeight: CGFloat = 24
  // Deterministic wrapping widths. These MUST be static constants, never
  // derived from bounds at layout time: deriving wrap widths from bounds
  // creates a width↔wrap feedback loop (width sets wrap, wrap sets intrinsic
  // height, height re-resolves width) that never converges — rows stagger,
  // icons stretch, and the window grows past 390pt.
  // Toggle-row text = 390 − 32 (content) − 14 − 20 − 10 − 12 − 44 − 14.
  static let rowTextWidth: CGFloat = 244
  // Hero text = 390 − 32 (content) − 16 (leading) − 12 (gap) − 124 (orb) − 8.
  static let heroTextWidth: CGFloat = 198
  // The meta row shares the hero text column with an 11 pt icon + 5 pt gap,
  // which the 198 pt budget did not account for: meta text at 198 widened the
  // whole panel to 407 pt on long attention copy (audit C2).
  static let heroMetaIconWidth: CGFloat = 11
  static let heroMetaIconGap: CGFloat = 5
  static let heroMetaTextWidth: CGFloat = heroTextWidth - heroMetaIconWidth - heroMetaIconGap
  /// Detail labels are capped at three lines: every shipped sentence (including
  /// the PWM qualification and the pending-restore message) fits inside that,
  /// and the panel scrolls rather than clipping if a state grows (audit C4).
  static let detailMaxLines: Int = 3
  static let stackSpacing: CGFloat = 10
  static let heroHeight: CGFloat = 128
  static let headerHeight: CGFloat = 40
  static let footerBarHeight: CGFloat = 36
  // Panel chrome around the scrolling document: top inset + footer gap + bar.
  static let panelTopInset: CGFloat = 12
  static let panelBottomGap: CGFloat = 10
  /// Space a popover loses above its content when anchored under the status
  /// item (status item + gap); used to clamp the content-driven height.
  static let popoverChromeHeight: CGFloat = 41
  static let panelMinHeight: CGFloat = 320
}


extension NSColor {
  func withAlpha(_ a: CGFloat) -> NSColor { withAlphaComponent(a) }
}
