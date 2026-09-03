import AppKit

enum EmberSliderVariant {
  case warmth
  case brightness
}

@MainActor
final class EmberSliderCell: NSSliderCell {
  var variant: EmberSliderVariant = .warmth
  var isWarmthPureRed: Bool = false

  private let thumbShadowColor = NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.18, alpha: 0.45)

  override func drawBar(inside rect: NSRect, flipped: Bool) {
    guard let controlView = controlView as? NSSlider else { return }
    let isEnabled = controlView.isEnabled
    let alpha: CGFloat = isEnabled ? 1 : 0.42

    let trackHeight: CGFloat = EmberMetrics.sliderTrackHeight
    // Inset the track by half the thumb plus padding so the 22pt thumb stays
    // fully visible at 0% and 100% (knobRect uses the same insets, keeping
    // track and knob mappings in agreement).
    let endInset = EmberMetrics.sliderEndInset
    let y = rect.midY - trackHeight/2
    let trackRect = NSRect(
      x: rect.minX + endInset, y: y,
      width: max(0, rect.width - (endInset * 2)), height: trackHeight)
    let path = NSBezierPath(roundedRect: trackRect, xRadius: trackHeight/2, yRadius: trackHeight/2)

    NSGraphicsContext.saveGraphicsState()
    // Background track (unfilled)
    NSColor(calibratedWhite: 0.22, alpha: alpha).setFill()
    path.fill()

    // Filled portion
    let valueRatio: CGFloat
    if maxValue == minValue { valueRatio = 0 }
    else { valueRatio = CGFloat((doubleValue - minValue) / (maxValue - minValue)) }
    let filledWidth = trackRect.width * valueRatio
    let filledRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: filledWidth, height: trackRect.height)
    let filledPath = NSBezierPath(roundedRect: filledRect, xRadius: trackHeight/2, yRadius: trackHeight/2)
    // Clip to create gradient within filled
    NSGraphicsContext.saveGraphicsState()
    filledPath.addClip()

    if variant == .warmth {
      // Fixed three-stop warmth gradient (neutral → evening → pure red),
      // clipped to the filled portion. Never replace the fill after 82%;
      // the left side must not jump color.
      let gradient = NSGradient(colors: [
        EmberColor.sliderTrackWarmNeutral.withAlphaComponent(alpha),
        EmberColor.sliderTrackWarmMid.withAlphaComponent(alpha),
        EmberColor.ember500.withAlphaComponent(alpha),
      ])!
      // Draw the full three-stop gradient across the entire track, clipped to fill.
      NSGraphicsContext.saveGraphicsState()
      // Clip already set to filledPath; draw gradient mapped to full track width
      // so the visible left side is stable as value changes.
      gradient.draw(in: trackRect, angle: 0)
      NSGraphicsContext.restoreGraphicsState()
    } else {
      // brightness: solid ember with dim to bright interpolation
      let start = EmberColor.sliderTrackDim.withAlphaComponent(alpha * 0.55)
      let end = EmberColor.sliderTrackBright.withAlphaComponent(alpha)
      let gradient = NSGradient(colors: [start, end])!
      gradient.draw(in: filledRect, angle: 0)
    }
    NSGraphicsContext.restoreGraphicsState()

    // Border subtle
    NSColor.white.withAlphaComponent(0.06 * alpha).setStroke()
    path.lineWidth = 1
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()
  }

  override func drawKnob(_ knobRect: NSRect) {
    guard let controlView = controlView else { return }
    let isEnabled = (controlView as? NSSlider)?.isEnabled ?? true
    let alpha: CGFloat = isEnabled ? 1 : 0.42

    let isHighlighted = isHighlighted
    let isDragging = controlView.window?.firstResponder == controlView // approximate

    let size = EmberMetrics.sliderThumb
    let x = knobRect.midX - size/2
    let y = knobRect.midY - size/2
    let thumbRect = NSRect(x: x, y: y, width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    // Shadow / glow
    let shadow = NSShadow()
    shadow.shadowColor = thumbShadowColor.withAlphaComponent(0.35 * alpha)
    shadow.shadowBlurRadius = isDragging || isHighlighted ? 14 : 10
    shadow.shadowOffset = CGSize(width: 0, height: 1)
    shadow.set()

    // Thumb circle
    let path = NSBezierPath(ovalIn: thumbRect)
    // Radial gradient
    let ctx = NSGraphicsContext.current?.cgContext
    let colors = [
      NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.42, alpha: alpha).cgColor,
      NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.22, alpha: alpha).cgColor,
      NSColor(calibratedRed: 0.86, green: 0.22, blue: 0.14, alpha: alpha).cgColor,
    ] as CFArray
    let locations: [CGFloat] = [0, 0.55, 1]
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations),
       let ctx {
      ctx.saveGState()
      ctx.addPath(path.cgPath)
      ctx.clip()
      ctx.drawRadialGradient(
        grad,
        startCenter: CGPoint(x: thumbRect.midX - 4, y: thumbRect.midY + 4),
        startRadius: 1,
        endCenter: CGPoint(x: thumbRect.midX, y: thumbRect.midY),
        endRadius: size/2,
        options: []
      )
      ctx.restoreGState()
    } else {
      NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.22, alpha: alpha).setFill()
      path.fill()
    }

    // Inner highlight
    let hlRect = NSRect(x: thumbRect.minX + 5, y: thumbRect.maxY - 8, width: 9, height: 4)
    let hlPath = NSBezierPath(ovalIn: hlRect)
    NSColor.white.withAlphaComponent(0.22 * alpha).setFill()
    hlPath.fill()

    // Border
    NSColor.white.withAlphaComponent(0.18 * alpha).setStroke()
    path.lineWidth = 1
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()

    // Outer ring when focused
    if controlView.window?.firstResponder == controlView {
      let ring = NSBezierPath(ovalIn: thumbRect.insetBy(dx: -2, dy: -2))
      EmberColor.ember500.withAlphaComponent(0.18).setStroke()
      ring.lineWidth = 2
      ring.stroke()
    }
  }

  override func knobRect(flipped: Bool) -> NSRect {
    // Map the value range onto the same inset track drawBar uses, so the knob
    // center always sits on the track and the full thumb stays in bounds.
    guard let slider = controlView as? NSSlider else { return super.knobRect(flipped: flipped) }
    let bounds = slider.bounds
    let endInset = EmberMetrics.sliderEndInset
    let usable = max(0, bounds.width - (endInset * 2))
    let ratio: CGFloat =
      maxValue == minValue ? 0 : CGFloat((doubleValue - minValue) / (maxValue - minValue))
    let centerX = endInset + (usable * min(max(ratio, 0), 1))
    let size = EmberMetrics.sliderThumb
    // NSSliderCell knob thickness follows the control height; center vertically.
    let knobHeight = super.knobRect(flipped: flipped).height
    let centerY = bounds.midY
    return NSRect(x: centerX - size / 2, y: centerY - knobHeight / 2, width: size, height: knobHeight)
  }
}

@MainActor
final class EmberSlider: NSSlider {
  var variant: EmberSliderVariant = .warmth {
    didSet { (cell as? EmberSliderCell)?.variant = variant; needsDisplay = true }
  }

  init(variant: EmberSliderVariant, value: Double, minValue: Double, maxValue: Double, target: AnyObject?, action: Selector?) {
    let cell = EmberSliderCell()
    cell.variant = variant
    super.init(frame: .zero)
    self.cell = cell
    self.variant = variant
    self.minValue = minValue
    self.maxValue = maxValue
    self.doubleValue = value
    self.target = target as AnyObject?
    self.action = action
    self.isContinuous = true
    self.controlSize = .regular
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override func awakeFromNib() {
    super.awakeFromNib()
    MainActor.assumeIsolated {
      if let c = cell as? EmberSliderCell { c.variant = variant }
    }
  }
}

// Helper to bridge CGPath from NSBezierPath
private extension NSBezierPath {
  var cgPath: CGPath {
    let path = CGMutablePath()
    var points = [CGPoint](repeating: .zero, count: 3)
    for i in 0..<elementCount {
      let type = element(at: i, associatedPoints: &points)
      switch type {
      case .moveTo: path.move(to: points[0])
      case .lineTo: path.addLine(to: points[0])
      case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
      case .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
      case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
      case .closePath: path.closeSubpath()
      @unknown default: break
      }
    }
    return path
  }
}
