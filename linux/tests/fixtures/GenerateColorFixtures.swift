import Foundation

private struct FixtureRow: Codable {
  let warmth: Double
  let brightness: Double
  let gains: [Float]
  let matrixDiagonal: [Double]
}

private struct Fixture: Codable {
  let schemaVersion = 1
  let referenceCommit = "41973930103c5c12c5c04715f4a1943ff759628d"
  let referenceFiles = ["Sources/EmberCore/Models.swift", "Sources/EmberCore/ColorCurve.swift"]
  let rows: [FixtureRow]
}

@main
private struct GenerateColorFixtures {
  static func main() throws {
    let warmthValues = [0.0, 0.01, 0.2, 0.62, 0.819999, 0.82, 0.820001, 0.9, 0.99, 1.0]
    let brightnessValues = [0.1, 0.75, 1.0]
    let rows = warmthValues.flatMap { warmth in
      brightnessValues.map { brightness in
        let gains = ColorCurve.gains(forWarmth: warmth)
        return FixtureRow(
          warmth: warmth,
          brightness: brightness,
          gains: [gains.red, gains.green, gains.blue],
          matrixDiagonal: [
            brightness * Double(gains.red),
            brightness * Double(gains.green),
            brightness * Double(gains.blue),
          ]
        )
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Fixture(rows: rows))
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}
