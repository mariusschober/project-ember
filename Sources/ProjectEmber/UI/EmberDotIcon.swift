import AppKit

@MainActor
enum EmberDotIcon {
  /// Inactive dot — calm, 8 px on a 16 pt canvas.
  ///
  /// Template on purpose: `NSStatusItem` follows the system appearance, and a
  /// fixed grey measured 3.00:1 on a light menu bar and 4.55:1 on a dark one
  /// (audit M5). A template image is tinted by the system (black on a light
  /// bar, white on a dark one), so the dot always contrasts.
  static func inactiveImage() -> NSImage {
    let image = makeDot(diameter: 8, color: .black, glow: false)
    image.isTemplate = true
    return image
  }

  /// Active ember dot — 12 px + soft glow, matches hero orb / app icon.
  ///
  /// Deliberately NOT a template: the brand ember is the app's identity in the
  /// menu bar. 2.93:1 on a light bar is acceptable for the *active* state
  /// because the size/shape cue and the tooltip carry the same information;
  /// the states that must be noticed are template-drawn below.
  static func activeImage() -> NSImage {
    let image = makeDot(diameter: 12, color: EmberColor.ember500, glow: true, glowAlpha: 0.28)
    image.isTemplate = false
    return image
  }

  /// Degraded/attention — a warning triangle, not an amber dot.
  ///
  /// Two fixes in one: amber #FF9E3D on a light menu bar measured 1.80:1
  /// (audit M5), and a colour-only difference is invisible to colour-blind
  /// users. A template warning shape is system-tinted *and* shape-distinct.
  static func degradedImage() -> NSImage {
    let image = makeAttentionGlyph()
    image.isTemplate = true
    return image
  }

  /// Exclamation-inside-triangle, 12x11 pt on the 16 pt canvas, drawn as an
  /// alpha mask: the exclamation is punched out so the bar shows through.
  private static func makeAttentionGlyph() -> NSImage {
    let canvas: CGFloat = 16
    let size = NSSize(width: canvas, height: canvas)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let cx = canvas / 2
    let cy = canvas / 2 + 0.5
    let width: CGFloat = 13
    let height: CGFloat = 11.5
    // Rounded triangle.
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: cx, y: cy + height / 2))
    triangle.addLine(to: CGPoint(x: cx + width / 2, y: cy - height / 2))
    triangle.addLine(to: CGPoint(x: cx - width / 2, y: cy - height / 2))
    triangle.closeSubpath()
    ctx.addPath(triangle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()

    // Punch the exclamation out of the solid triangle.
    ctx.setBlendMode(.clear)
    let barWidth: CGFloat = 1.8
    let barBottom = cy - height * 0.22
    let barTop = cy + height * 0.28
    ctx.fill(CGRect(x: cx - barWidth / 2, y: barBottom, width: barWidth, height: barTop - barBottom))
    let dotDiameter: CGFloat = 1.9
    ctx.fillEllipse(
      in: CGRect(
        x: cx - dotDiameter / 2, y: barBottom - 3.1, width: dotDiameter, height: dotDiameter))
    ctx.setBlendMode(.normal)
    return image
  }

  /// Header orb — 28px canvas, 20px orb + glow + highlight, replaces flame
  static func headerImage() -> NSImage {
    let size = NSSize(width: 28, height: 28)
    let img = NSImage(size: size)
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let cx = size.width/2
    let cy = size.height/2
    let orb: CGFloat = 20
    let glow: CGFloat = orb + 8

    // Glow
    ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.24, blue: 0.13, alpha: 0.22).cgColor)
    ctx.addEllipse(in: NSRect(x: cx - glow/2, y: cy - glow/2, width: glow, height: glow))
    ctx.setShadow(offset: .zero, blur: 6, color: NSColor(calibratedRed: 1, green: 0.30, blue: 0.18, alpha: 0.9).cgColor)
    ctx.fillPath()

    // Orb base gradient approximation via 3 circles
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Outer #C73217
    ctx.setFillColor(NSColor(calibratedRed: 0.78, green: 0.20, blue: 0.09, alpha: 1).cgColor)
    ctx.addEllipse(in: NSRect(x: cx - orb/2, y: cy - orb/2, width: orb, height: orb))
    ctx.fillPath()
    // Mid #FF3B1E 82%
    let mid = orb * 0.82
    ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.23, blue: 0.12, alpha: 1).cgColor)
    ctx.addEllipse(in: NSRect(x: cx - mid/2, y: cy - mid/2, width: mid, height: mid))
    ctx.fillPath()
    // Inner #FF6236 offset top-left
    let inner = orb * 0.58
    ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.38, blue: 0.21, alpha: 1).cgColor)
    ctx.addEllipse(in: NSRect(x: cx - inner/2 + orb*0.05, y: cy - inner/2 + orb*0.05, width: inner, height: inner))
    ctx.fillPath()

    // Highlight white @14
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    let hlW = orb * 0.32
    let hlH = orb * 0.18
    ctx.addEllipse(in: NSRect(x: cx - orb*0.15, y: cy + orb*0.18, width: hlW, height: hlH))
    ctx.fillPath()

    img.unlockFocus()
    img.isTemplate = false
    return img
  }

  private static func makeDot(diameter: CGFloat, color: NSColor, glow: Bool, glowAlpha: CGFloat = 0.22) -> NSImage {
    let canvas: CGFloat = 16
    let size = NSSize(width: canvas, height: canvas)
    let img = NSImage(size: size)
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }
    ctx.setAllowsAntialiasing(true)
    let cx = canvas/2
    let cy = canvas/2 + 0.5 // optical center for menu bar (1px up)

    if glow {
      let glowD = diameter + 6
      ctx.setFillColor(color.withAlphaComponent(glowAlpha).cgColor)
      ctx.addEllipse(in: NSRect(x: cx - glowD/2, y: cy - glowD/2, width: glowD, height: glowD))
      ctx.setShadow(offset: .zero, blur: 4, color: color.withAlphaComponent(0.85).cgColor)
      ctx.fillPath()
      ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    // Base dot with subtle inner gradient via two circles
    ctx.setFillColor(color.cgColor)
    ctx.addEllipse(in: NSRect(x: cx - diameter/2, y: cy - diameter/2, width: diameter, height: diameter))
    ctx.fillPath()

    // Delineating rim for the brand-coloured active dot. Ember on a light menu
    // bar measures ~2.6:1, below the 3:1 WCAG 1.4.11 asks of a graphical
    // object; a dark rim gives it a legible edge in Light Mode and disappears
    // into a dark bar, where the ember core already contrasts 6.7:1.
    if glow {
      ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.9).cgColor)
      ctx.setLineWidth(1.5)
      let rim = diameter + 1.5
      ctx.strokeEllipse(in: NSRect(x: cx - rim/2, y: cy - rim/2, width: rim, height: rim))
    }

    // Inner lighter center for ember active (radial)
    if glow {
      let inner = diameter * 0.62
      ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.62, blue: 0.42, alpha: 1).cgColor)
      ctx.setAlpha(0.55)
      ctx.addEllipse(in: NSRect(x: cx - inner/2, y: cy - inner/2 + diameter*0.1, width: inner, height: inner))
      ctx.fillPath()
      ctx.setAlpha(1)
      // highlight
      ctx.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor)
      let hl = diameter * 0.28
      ctx.addEllipse(in: NSRect(x: cx - hl/2, y: cy + diameter*0.18, width: hl, height: hl*0.6))
      ctx.fillPath()
    }

    img.unlockFocus()
    img.isTemplate = false
    // For menu bar, ensure correct scaling for Retina
    img.size = size
    return img
  }
}
