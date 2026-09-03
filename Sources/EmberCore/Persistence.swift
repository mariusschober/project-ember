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

public final class RecoveryJournal: @unchecked Sendable {
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

  public var backupURL: URL {
    fileURL.deletingPathExtension().appendingPathExtension("last-good.json")
  }

  public var quarantineURL: URL {
    fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
  }

  public func load() throws -> RecoveryRecord? {
    switch loadOutcome() {
    case .noJournal: return nil
    case .loaded(let record): return record
    case .unsupportedFutureSchema(let version):
      throw EmberError.journalUnsupportedSchema(version)
    case .corrupt(let reason):
      throw EmberError.journalCorrupt(reason)
    case .ioFailure(let message):
      throw EmberError.recoveryFailed(message)
    }
  }

  /// Explicit load outcome. Corrupt journals are never reported as absent.
  public func loadOutcome() -> JournalLoadOutcome {
    guard exists else { return .noJournal }
    do {
      let data = try Data(contentsOf: fileURL)
      guard !data.isEmpty else { return .corrupt(reason: "Recovery journal is empty") }
      do {
        let record = try decoder.decode(RecoveryRecord.self, from: data)
        return .loaded(record)
      } catch let error as DecodingError {
        let description = String(describing: error)
        if description.contains("Unsupported recovery schema") {
          // Extract version if present, else -1.
          return .unsupportedFutureSchema(version: Self.extractSchemaVersion(from: data) ?? -1)
        }
        return .corrupt(reason: description)
      } catch {
        return .corrupt(reason: error.localizedDescription)
      }
    } catch {
      let ns = error as NSError
      if ns.domain == NSCocoaErrorDomain
        && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError)
      {
        return .noJournal
      }
      return .ioFailure(error.localizedDescription)
    }
  }

  public func save(_ record: RecoveryRecord) throws {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    // Keep a last-known-good backup before overwriting a valid journal.
    if exists, let current = try? Data(contentsOf: fileURL), !current.isEmpty,
      (try? decoder.decode(RecoveryRecord.self, from: current)) != nil
    {
      try? current.write(to: backupURL, options: [.atomic])
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    }
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

  /// Quarantine an unreadable journal instead of deleting it.
  @discardableResult
  public func quarantineCorruptJournal() -> URL? {
    guard exists else { return nil }
    do {
      if fileManager.fileExists(atPath: quarantineURL.path) {
        try? fileManager.removeItem(at: quarantineURL)
      }
      try fileManager.moveItem(at: fileURL, to: quarantineURL)
      return quarantineURL
    } catch {
      return nil
    }
  }

  public func clear() throws {
    guard exists else { return }
    try fileManager.removeItem(at: fileURL)
  }

  private static func extractSchemaVersion(from data: Data) -> Int? {
    guard let obj = try? JSONSerialization.jsonObject(with: data),
      let dict = obj as? [String: Any]
    else { return nil }
    return dict["schemaVersion"] as? Int
  }
}
