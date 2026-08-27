import AppKit

@MainActor
enum EmberDotIcon {
  /// Inactive grey dot — calm, 8px on 16 canvas
  static func inactiveImage() -> NSImage {
    makeDot(diameter: 8, color: NSColor(calibratedRed: 0.56, green: 0.54, blue: 0.53, alpha: 1.0), glow: false)
  }

  /// Active ember dot — larger 12px + soft glow, matches hero orb / app icon
  static func activeImage() -> NSImage {
    makeDot(diameter: 12, color: EmberColor.ember500, glow: true, glowAlpha: 0.28)
  }

  /// Degraded — amber dot (attention) slightly larger than inactive, no glow
  static func degradedImage() -> NSImage {
    makeDot(diameter: 10, color: EmberColor.warning, glow: false)
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
