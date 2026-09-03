import Foundation

// MARK: - Desired / observed / presentation separation (0.4.0)
//
// Observed truth drives the UI: "active" means the requested table has been
// read back successfully on at least one intended online display.
// Desired state alone is insufficient.

public enum EmberOperationState: Equatable, Sendable {
  case off
  case activating
  case active
  case reconciling
  case restoring
  case suspended
  case degraded
}

public enum AttentionSeverity: Equatable, Sendable {
  case none
  case info
  case warning
  case error
}

public struct AttentionState: Equatable, Sendable {
  public let severity: AttentionSeverity
  public let title: String
  public let message: String
  public let recoveryActions: [String]

  public init(severity: AttentionSeverity, title: String, message: String, recoveryActions: [String] = []) {
    self.severity = severity
    self.title = title
    self.message = message
    self.recoveryActions = recoveryActions
  }

  public static let none = AttentionState(severity: .none, title: "", message: "")
}

public struct DisplayCountSummary: Equatable, Sendable {
  public var verified: Int
  public var unsupported: Int
  public var pending: Int
  public var failed: Int

  public init(verified: Int = 0, unsupported: Int = 0, pending: Int = 0, failed: Int = 0) {
    self.verified = verified
    self.unsupported = unsupported
    self.pending = pending
    self.failed = failed
  }
}

/// Single coherent presentation model. UI renders from this — never reinterprets
/// raw coordinator state separately.
public struct EmberPresentation: Equatable, Sendable {
  public let desiredFilterEnabled: Bool
  public let operationState: EmberOperationState
  /// True only when >=1 intended online display has a verified transform.
  public let isObservedActive: Bool
  public let counts: DisplayCountSummary
  public let attention: AttentionState
  public let statusTitle: String
  public let statusDetail: String

  public init(
    desiredFilterEnabled: Bool,
    operationState: EmberOperationState,
    isObservedActive: Bool,
    counts: DisplayCountSummary,
    attention: AttentionState,
    statusTitle: String,
    statusDetail: String
  ) {
    self.desiredFilterEnabled = desiredFilterEnabled
    self.operationState = operationState
    self.isObservedActive = isObservedActive
    self.counts = counts
    self.attention = attention
    self.statusTitle = statusTitle
    self.statusDetail = statusDetail
  }

  /// User-facing "active" — observed truth, not desire.
  public var showsActive: Bool { isObservedActive && attention.severity != .error }
}

public enum EmberPresenter {
  public static func make(
    desiredOn: Bool,
    operation: EmberOperationState,
    verified: Set<String>,
    unsupported: Int,
    pending: Int,
    failed: [String],
    onlineIntended: Int,
    attentionOverride: AttentionState? = nil
  ) -> EmberPresentation {
    let counts = DisplayCountSummary(
      verified: verified.count,
      unsupported: unsupported,
      pending: pending,
      failed: failed.count
    )
    let observedActive = desiredOn && !verified.isEmpty && operation != .restoring
    let attention: AttentionState
    let title: String
    let detail: String
    if let attentionOverride, attentionOverride.severity != .none {
      attention = attentionOverride
      title = attentionOverride.title
      detail = attentionOverride.message
    } else if !failed.isEmpty {
      attention = AttentionState(
        severity: .error,
        title: "Needs attention",
        message: failed.joined(separator: " "),
        recoveryActions: ["Retry", "Reset"]
      )
      title = "Needs attention"
      detail = failed.joined(separator: " ")
    } else if desiredOn, observedActive {
      attention = .none
      title = "Ember is on"
      if pending > 0 {
        detail = "Active on \(verified.count) \(verified.count == 1 ? "display" : "displays")."
      } else if unsupported > 0 {
        detail =
          "Active on \(verified.count) of \(onlineIntended) displays; unsupported displays were left untouched."
      } else {
        detail = "Color and software brightness are active on \(verified.count) \(verified.count == 1 ? "display" : "displays")."
      }
    } else if desiredOn, pending > 0, verified.isEmpty {
      // Pending-only disconnected: calm but truthful, never false alarm.
      attention = AttentionState(
        severity: .info,
        title: "Waiting for display",
        message: "Ember saved your original colors for \(pending) display(s) you unplugged — they’ll be restored when you reconnect.",
        recoveryActions: []
      )
      title = "Ember is off"
      detail = "Your displays look normal."
    } else if desiredOn {
      attention = AttentionState(
        severity: .warning,
        title: "Ember is on",
        message: "Waiting for verification on \(onlineIntended) display(s).",
        recoveryActions: ["Retry"]
      )
      title = "Applying"
      detail = "Verifying every display…"
    } else {
      attention = .none
      if onlineIntended > 0 {
        title = "Ready"
        detail = "\(onlineIntended) compatible \(onlineIntended == 1 ? "display" : "displays") ready; original state untouched."
      } else {
        title = "No compatible display"
        detail = "Connect a display that supports macOS color tables."
      }
    }
    return EmberPresentation(
      desiredFilterEnabled: desiredOn,
      operationState: operation,
      isObservedActive: observedActive,
      counts: counts,
      attention: attention,
      statusTitle: title,
      statusDetail: detail
    )
  }
}
