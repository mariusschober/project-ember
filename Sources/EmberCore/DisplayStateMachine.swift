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
  case reconciling
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
  case reconciliationStarted
  case reconciliationSucceeded
  case reconciliationFailed(String)
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
  case verifyObservedState
  case publishPresentation
}

public struct DisplayStateMachine: Sendable {
  public private(set) var state: DisplayRuntimeState

  public init(state: DisplayRuntimeState = .off) {
    self.state = state
  }

  @discardableResult
  public mutating func transition(_ event: DisplayEvent) -> [DisplayAction] {
    switch (state, event) {
    case (.off, .enableRequested), (.degraded, .enableRequested):
      state = .activating
      return [.captureBaseline, .saveRecoveryRecord, .applyTransform]

    // Topology change during activation: move to reconciling, never blanket-restore.
    case (.activating, .displayChanged):
      state = .reconciling
      return [.verifyObservedState]

    // Topology change during restore: stay restoring; reconciliation resumes after.
    case (.restoring, .displayChanged):
      return [.verifyObservedState]

    case (.activating, .activationSucceeded):
      state = .active
      return [.startBacklightGuard, .publishPresentation]

    case (.activating, let .activationFailed(message)):
      state = .degraded(message)
      return [.stopBacklightGuard, .restoreBaseline, .publishPresentation]

    case (.active, .disableRequested), (.activating, .disableRequested),
      (.degraded, .disableRequested), (.reconciling, .disableRequested),
      (.suspended, .disableRequested):
      state = .restoring(.disable)
      return [.stopBacklightGuard, .restoreBaseline]

    case (.active, .sleepRequested), (.degraded, .sleepRequested),
      (.reconciling, .sleepRequested):
      // Degraded sleep path was missing: degraded with a journal must still
      // restore before suspend so a stuck table never survives sleep.
      state = .restoring(.sleep)
      return [.stopBacklightGuard, .restoreBaseline]

    case (.suspended, .sleepRequested):
      return []

    case (.active, .terminationRequested), (.activating, .terminationRequested),
      (.degraded, .terminationRequested), (.reconciling, .terminationRequested),
      (.suspended, .terminationRequested):
      state = .restoring(.terminate)
      return [.stopBacklightGuard, .restoreBaseline]

    case (.restoring(let intent), .restoreSucceeded):
      state = intent == .sleep ? .suspended : .off
      return [.clearRecoveryRecord, .publishPresentation]

    case (.restoring, let .restoreFailed(message)):
      state = .degraded(message)
      return [.publishPresentation]

    case (.active, .settingsChanged):
      return [.applyTransform, .synchronizeBacklight]

    case (.active, .displayChanged):
      state = .reconciling
      return [.verifyObservedState]

    case (.reconciling, .reconciliationSucceeded):
      // Caller decides active vs degraded from observed verification.
      state = .active
      return [.publishPresentation]

    case (.reconciling, let .reconciliationFailed(message)):
      state = .degraded(message)
      return [.publishPresentation]

    case (.reconciling, .settingsChanged):
      return [.applyTransform]

    case (.degraded, .displayChanged), (.off, .displayChanged), (.suspended, .displayChanged):
      // Pending disconnected displays without false alarm: no state change,
      // just re-verify so reconnect can complete pending recovery silently.
      return [.verifyObservedState]

    case (.suspended, .wakeRequested):
      state = .activating
      return [.captureBaseline, .saveRecoveryRecord, .applyTransform]

    default:
      return []
    }
  }
}
