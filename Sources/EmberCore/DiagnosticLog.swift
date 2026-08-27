import Foundation

public struct DiagnosticEntry: Equatable, Sendable {
  public let timestamp: Date
  public let level: String
  public let message: String

  public init(timestamp: Date = Date(), level: String, message: String) {
    self.timestamp = timestamp
    self.level = level
    self.message = message
  }
}

public final class DiagnosticLog: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [DiagnosticEntry] = []
  private let capacity: Int

  public init(capacity: Int = 200) {
    self.capacity = max(capacity, 1)
  }

  public func append(_ message: String, level: String = "INFO") {
    lock.lock()
    defer { lock.unlock() }
    storage.append(DiagnosticEntry(level: level, message: message))
    if storage.count > capacity {
      storage.removeFirst(storage.count - capacity)
    }
  }

  public func entries() -> [DiagnosticEntry] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  public func formattedText() -> String {
    // ISO8601DateFormatter is not Sendable/thread-safe for static sharing;
    // formatting occurs rarely (diagnostics window), so per-call allocation
    // is negligible and avoids data races.
    let formatter = ISO8601DateFormatter()
    return entries().map {
      "\(formatter.string(from: $0.timestamp)) [\($0.level)] \($0.message)"
    }.joined(separator: "\n")
  }
}
