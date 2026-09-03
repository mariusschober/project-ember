import Foundation

// MARK: - Fail-safe journal outcomes (0.4.0)
//
// A corrupt journal must never be treated as an empty journal and then cleared.

public enum JournalLoadOutcome: Equatable, Sendable {
  case noJournal
  case loaded(RecoveryRecord)
  case unsupportedFutureSchema(version: Int)
  case corrupt(reason: String)
  case ioFailure(String)
}

public enum RestoreOutcome: Equatable, Sendable {
  case restoredAndVerified(identity: DisplayIdentity)
  case displayOfflinePending(identity: DisplayIdentity)
  case identityAmbiguous(reason: String)
  case gammaWriteFailed(identity: DisplayIdentity, message: String)
  case gammaReadbackMismatch(identity: DisplayIdentity, delta: Float)
  case hardwareRestoreFailed(identity: DisplayIdentity, message: String)
  case hardwareReadbackMismatch(identity: DisplayIdentity, message: String)
  case resolveFailed(message: String)

  public var isSuccess: Bool {
    if case .restoredAndVerified = self { return true }
    return false
  }

  public var isPendingOffline: Bool {
    if case .displayOfflinePending = self { return true }
    return false
  }
}

public struct RestoreReport: Equatable, Sendable {
  public let outcomes: [RestoreOutcome]
  /// Entries that must remain journaled (every non-verified outcome with identity).
  public let remaining: [DisplayRecoveryEntry]

  public init(outcomes: [RestoreOutcome], remaining: [DisplayRecoveryEntry]) {
    self.outcomes = outcomes
    self.remaining = remaining
  }

  public var verifiedCount: Int { outcomes.filter(\.isSuccess).count }
  public var hasFailure: Bool { outcomes.contains { !$0.isSuccess && !$0.isPendingOffline } }
}
