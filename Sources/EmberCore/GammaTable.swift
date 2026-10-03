import Foundation

public struct GammaTable: Codable, Equatable, Sendable {
  public let red: [Float]
  public let green: [Float]
  public let blue: [Float]

  public init(red: [Float], green: [Float], blue: [Float]) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  public var sampleCount: Int {
    red.count
  }

  public var isValid: Bool {
    red.count >= 2
      && red.count == green.count
      && green.count == blue.count
      && red.allSatisfy(\.isFinite)
      && green.allSatisfy(\.isFinite)
      && blue.allSatisfy(\.isFinite)
  }

  /// Stricter check for a table that came from disk and is about to be written
  /// to a panel. `isValid` accepts any non-empty shape because a table read from
  /// a display is trusted; a *decoded* table is not. A single-sample table
  /// resamples into a constant one (`resample` repeats the only value), which
  /// would nail the panel to one value and destroy what the user actually had,
  /// so a flat table is rejected here rather than written.
  public var isPlausibleBaseline: Bool {
    guard isValid else { return false }
    let redConstant = red.allSatisfy { $0 == red[0] }
    let greenConstant = green.allSatisfy { $0 == green[0] }
    let blueConstant = blue.allSatisfy { $0 == blue[0] }
    return !(redConstant && greenConstant && blueConstant)
  }

  public static func identity(sampleCount: Int = 256) -> GammaTable {
    let count = max(sampleCount, 2)
    let values = (0..<count).map { Float($0) / Float(count - 1) }
    return GammaTable(red: values, green: values, blue: values)
  }

  public func applying(gains: ColorGains, apparentBrightness: Double) -> GammaTable {
    let brightness = Float(min(max(apparentBrightness, 0.10), 1))
    return GammaTable(
      red: red.map { min(max($0 * gains.red * brightness, 0), 1) },
      green: green.map { min(max($0 * gains.green * brightness, 0), 1) },
      blue: blue.map { min(max($0 * gains.blue * brightness, 0), 1) }
    )
  }

  public func resampled(to targetCount: Int) -> GammaTable {
    let count = max(targetCount, 2)
    guard isValid, count != sampleCount else { return self }
    return GammaTable(
      red: Self.resample(red, to: count),
      green: Self.resample(green, to: count),
      blue: Self.resample(blue, to: count)
    )
  }

  public func maximumAbsoluteDifference(from other: GammaTable) -> Float {
    guard isValid, other.isValid else { return .infinity }
    let rhs = other.resampled(to: sampleCount)
    var difference: Float = 0
    for index in 0..<sampleCount {
      difference = max(difference, abs(red[index] - rhs.red[index]))
      difference = max(difference, abs(green[index] - rhs.green[index]))
      difference = max(difference, abs(blue[index] - rhs.blue[index]))
    }
    return difference
  }

  private static func resample(_ values: [Float], to count: Int) -> [Float] {
    guard values.count > 1 else { return Array(repeating: values.first ?? 0, count: count) }
    return (0..<count).map { index in
      let position = Double(index) * Double(values.count - 1) / Double(count - 1)
      let lower = Int(floor(position))
      let upper = min(lower + 1, values.count - 1)
      let fraction = Float(position - Double(lower))
      return values[lower] + ((values[upper] - values[lower]) * fraction)
    }
  }
}
