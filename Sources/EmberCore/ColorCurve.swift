import Foundation

public enum ColorCurve {
  /// Maps a user-friendly 0...1 warmth value to a neutral-to-red gain curve.
  /// The first 82% follows a 6500 K to 2000 K black-body approximation. The
  /// final 18% deliberately fades to red and is described as "Pure Red", not
  /// as a physically meaningful color temperature.
  public static func gains(forWarmth warmth: Double) -> ColorGains {
    let amount = min(max(warmth, 0), 1)
    if amount == 0 { return .neutral }

    let redTailStart = 0.82
    if amount <= redTailStart {
      let progress = smoothstep(amount / redTailStart)
      let kelvin = 6500 - (4500 * progress)
      return gains(forKelvin: kelvin)
    }

    let base = gains(forKelvin: 2000)
    let progress = smoothstep((amount - redTailStart) / (1 - redTailStart))
    return ColorGains(
      red: interpolate(base.red, 1, progress),
      green: interpolate(base.green, 0, progress),
      blue: interpolate(base.blue, 0, progress)
    )
  }

  public static func approximateKelvin(forWarmth warmth: Double) -> Double? {
    let amount = min(max(warmth, 0), 1)
    guard amount <= 0.82 else { return nil }
    return 6500 - (4500 * smoothstep(amount / 0.82))
  }

  public static func gains(forKelvin kelvin: Double) -> ColorGains {
    let temperature = min(max(kelvin, 1667), 25000)
    if abs(temperature - 6500) < 0.5 { return .neutral }

    let x: Double
    if temperature <= 4000 {
      x =
        (-0.2661239e9 / pow(temperature, 3))
        - (0.2343580e6 / pow(temperature, 2))
        + (0.8776956e3 / temperature)
        + 0.179910
    } else {
      x =
        (-3.0258469e9 / pow(temperature, 3))
        + (2.1070379e6 / pow(temperature, 2))
        + (0.2226347e3 / temperature)
        + 0.240390
    }

    let y: Double
    if temperature <= 2222 {
      y =
        (-1.1063814 * pow(x, 3))
        - (1.34811020 * pow(x, 2))
        + (2.18555832 * x)
        - 0.20219683
    } else if temperature <= 4000 {
      y =
        (-0.9549476 * pow(x, 3))
        - (1.37418593 * pow(x, 2))
        + (2.09137015 * x)
        - 0.16748867
    } else {
      y =
        (3.0817580 * pow(x, 3))
        - (5.87338670 * pow(x, 2))
        + (3.75112997 * x)
        - 0.37001483
    }

    let luminance = 1.0
    let capitalX = x / y
    let capitalZ = (1 - x - y) / y

    let red = (3.2404542 * capitalX) - (1.5371385 * luminance) - (0.4985314 * capitalZ)
    let green = (-0.9692660 * capitalX) + (1.8760108 * luminance) + (0.0415560 * capitalZ)
    let blue = (0.0556434 * capitalX) - (0.2040259 * luminance) + (1.0572252 * capitalZ)
    let maximum = max(red, green, blue, 0.000_001)

    return ColorGains(
      red: Float(max(red / maximum, 0)),
      green: Float(max(green / maximum, 0)),
      blue: Float(max(blue / maximum, 0))
    )
  }

  private static func smoothstep(_ value: Double) -> Double {
    let t = min(max(value, 0), 1)
    return t * t * (3 - (2 * t))
  }

  private static func interpolate(_ start: Float, _ end: Float, _ progress: Double) -> Float {
    start + ((end - start) * Float(progress))
  }
}
