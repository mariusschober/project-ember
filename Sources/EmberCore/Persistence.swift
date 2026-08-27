import Foundation

public final class SettingsStore {
  private let defaults: UserDefaults
  private let key: String
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(defaults: UserDefaults = .standard, key: String = "projectEmber.settings.v2") {
    self.defaults = defaults
    self.key = key
  }

  public func load() -> EmberSettings {
    guard let data = defaults.data(forKey: key),
      var settings = try? decoder.decode(EmberSettings.self, from: data)
    else {
      return .default
    }
    settings.normalize()
    return settings
  }

  public func save(_ settings: EmberSettings) throws {
    var normalized = settings
    normalized.normalize()
    defaults.set(try encoder.encode(normalized), forKey: key)
  }
}

public final class SolarLocationStore {
  private let defaults: UserDefaults
  private let key: String
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(defaults: UserDefaults = .standard, key: String = "projectEmber.solarLocation.v1") {
    self.defaults = defaults
    self.key = key
  }

  public func load() -> CachedSolarLocation? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? decoder.decode(CachedSolarLocation.self, from: data)
  }

  public func save(_ location: CachedSolarLocation) throws {
    defaults.set(try encoder.encode(location), forKey: key)
  }

  public func clear() {
    defaults.removeObject(forKey: key)
  }
}

public final class RecoveryJournal {
  public let fileURL: URL
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    encoder = JSONEncoder()
    // SortedKeys for determinism, but no prettyPrinted to halve file size and
    // reduce write amplification on the journal which is rewritten on each slider
    // coalesce and state change.
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
  }

  public var exists: Bool {
    fileManager.fileExists(atPath: fileURL.path)
  }

  public func load() throws -> RecoveryRecord? {
    guard exists else { return nil }
    // Validate file is not empty/truncated before decoding
    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty else { throw EmberError.recoveryFailed("Recovery journal is empty") }
    return try decoder.decode(RecoveryRecord.self, from: data)
  }

  public func save(_ record: RecoveryRecord) throws {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let data = try encoder.encode(record)
    // Atomic write prevents torn journal on crash or power loss
    try data.write(to: fileURL, options: [.atomic])
    // Restrict to user-only and exclude from backup (contains display serials)
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    var url = fileURL
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
  }

  public func clear() throws {
    guard exists else { return }
    try fileManager.removeItem(at: fileURL)
  }
}
