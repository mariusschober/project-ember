import Foundation

public enum RestoreIntent: Equatable, Sendable {
  case disable
  case sleep
  case terminate
  case recovery
}

public enum DisplayRuntimeState: Equatable, Sendable {
  case off
  case activating
  case active
  case restoring(RestoreIntent)
  case suspended
  case degraded(String)
}

public enum DisplayEvent: Equatable, Sendable {
  case enableRequested
  case activationSucceeded
  case activationFailed(String)
  case disableRequested
  case sleepRequested
  case wakeRequested
  case terminationRequested
  case restoreSucceeded
  case restoreFailed(String)
  case settingsChanged
  case displayChanged
}

public enum DisplayAction: Equatable, Sendable {
  case captureBaseline
  case saveRecoveryRecord
  case applyTransform
  case restoreBaseline
  case clearRecoveryRecord
  case startBacklightGuard
  case stopBacklightGuard
  case synchronizeBacklight
}

public struct DisplayStateMachine: Sendable {
  public private(set) var state: DisplayRuntimeState

  public init(state: DisplayRuntimeState = .off) {
    self.state = state
  }

  @discardableResult
  public mutating func transition(_ event: DisplayEvent) -> [DisplayAction] {
    switch (state, event) {
    case (.off, .enableRequested), (.degraded, .enableRequested), (.suspended, .wakeRequested):
      state = .activating
      return [.captureBaseline, .saveRecoveryRecord, .applyTransform]

    case (.activating, .activationSucceeded):
      state = .active
      return [.startBacklightGuard]

    case (.activating, let .activationFailed(message)):
      state = .degraded(message)
      return [.stopBacklightGuard, .restoreBaseline, .clearRecoveryRecord]

    case (.active, .disableRequested), (.activating, .disableRequested),
      (.degraded, .disableRequested):
      state = .restoring(.disable)
      return [.stopBacklightGuard, .restoreBaseline]

    case (.active, .sleepRequested):
      state = .restoring(.sleep)
      return [.stopBacklightGuard, .restoreBaseline]

    case (.active, .terminationRequested), (.activating, .terminationRequested),
      (.degraded, .terminationRequested):
      state = .restoring(.terminate)
      return [.stopBacklightGuard, .restoreBaseline]

    case (.restoring(let intent), .restoreSucceeded):
      state = intent == .sleep ? .suspended : .off
      return [.clearRecoveryRecord]

    case (.restoring, let .restoreFailed(message)):
      state = .degraded(message)
      return []

    case (.active, .settingsChanged):
      return [.applyTransform, .synchronizeBacklight]

    case (.active, .displayChanged):
      return [.applyTransform, .synchronizeBacklight]

    default:
      return []
    }
  }
}
