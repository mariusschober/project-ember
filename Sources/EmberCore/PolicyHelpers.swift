import Foundation

// MARK: - Pure policy helpers
//
// These are the single source of truth for rules the app applies at runtime:
// the coordinator, the display controller and the solar controller call them
// rather than inlining a copy. 0.4.0 declared them and then duplicated the
// logic, so the tests covering them proved nothing about the shipped app.

/// Tracks external-override timestamps per display; bounded recovery enters a
/// truthful degraded state after `threshold` resets within `window` instead of
/// fighting forever.
public struct OverrideTracker: Equatable, Sendable {
  private var history: [String: [Date]] = [:]
  private let window: TimeInterval
  private let threshold: Int

  public init(window: TimeInterval = 60, threshold: Int = 3) {
    self.window = window
    self.threshold = max(threshold, 1)
  }

  /// Records a detected reset. Returns true when the bounded threshold is crossed.
  public mutating func recordReset(key: String, at date: Date = Date()) -> Bool {
    var list = history[key] ?? []
    list.append(date)
    list = list.filter { date.timeIntervalSince($0) < window }
    history[key] = list
    return list.count >= threshold
  }

  public func count(key: String, at date: Date = Date()) -> Int {
    (history[key] ?? []).filter { date.timeIntervalSince($0) < window }.count
  }

  public mutating func reset() { history.removeAll() }
}

/// Menu-bar primary-click routing (pure; coordinator enforces busy coalescing).
public enum MenuBarRouting: Sendable {
  public enum Result: Equatable, Sendable {
    case openControls
    case toggleOn
    case toggleOff
    case ignoredBusy
  }

  public static func route(
    action: MenuBarPrimaryAction,
    isBusy: Bool,
    isRightClick: Bool,
    isObservedActive: Bool,
    filterEnabled: Bool
  ) -> Result {
    if isBusy { return .ignoredBusy }
    if isRightClick { return .openControls }
    switch action {
    case .openControls: return .openControls
    case .toggleEmber:
      let turningOn = !filterEnabled || !isObservedActive
      return turningOn ? .toggleOn : .toggleOff
    }
  }
}

/// Backlight drift check (pure): write only when below threshold or ambient re-enabled.
public enum BacklightDriftCheck: Sendable {
  public static func needsWrite(
    currentBrightness: Float?,
    ambientEnabled: Bool?,
    threshold: Float = 0.97
  ) -> Bool {
    if let b = currentBrightness, b < threshold { return true }
    if currentBrightness == nil { return false }
    if ambientEnabled == true { return true }
    return false
  }

  /// Built-in-only targeting rule.
  public static func mayEngage(isBuiltIn: Bool) -> Bool { isBuiltIn }
}

/// Location freshness validation (pure): reject stale cached Core Location fixes.
public enum LocationFreshness: Sendable {
  public static let maxAge: TimeInterval = 5 * 60
  public static func isFresh(locationTimestamp: Date, now: Date) -> Bool {
    let age = now.timeIntervalSince(locationTimestamp)
    return age >= -60 && age <= maxAge
  }
}

/// Preset index for warmth (pure; custom → -1 so UI clears all highlights).
public enum PresetMatching: Sendable {
  public static func index(forWarmth warmth: Double) -> Int {
    if abs(warmth - EmberPreset.neutral.warmth) < 0.01 { return 0 }
    if abs(warmth - EmberPreset.evening.warmth) < 0.01 { return 1 }
    if abs(warmth - EmberPreset.pureRed.warmth) < 0.01 { return 2 }
    return -1
  }
}

/// Legacy resolver safety (pure): v1 built-in records never resolve to external.
public enum LegacyResolver: Sendable {
  public static func mayResolveToCandidate(
    legacyIsBuiltIn: Bool,
    exactIDMatch: Bool,
    candidateIsBuiltIn: Bool
  ) -> Bool {
    if exactIDMatch { return candidateIsBuiltIn }
    guard legacyIsBuiltIn else { return false }
    return candidateIsBuiltIn
  }
}
