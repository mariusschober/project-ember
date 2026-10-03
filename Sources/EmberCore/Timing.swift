import Foundation

/// Timer intervals that more than one layer depends on.
///
/// These live in EmberCore so the coordinator and the hardware self-tests can
/// never drift apart: a self-test that waits for "one guard interval" must wait
/// for the interval the coordinator actually schedules, not a copy of it.
public enum EmberTiming {
  /// Backlight Lock drift guard. The guard only reads (brightness plus ambient
  /// compensation) and writes solely on measured drift, so this interval trades
  /// correction latency against wakeups: 30 s costs ~120 wakeups/hour, the 0.4.0
  /// value of 5 s cost ~720 for a scalar that rarely changes.
  public static let backlightGuardInterval: TimeInterval = 30
  public static let backlightGuardTolerance: TimeInterval = 5

  /// Sparse verification while a transform is installed. Only scheduled while
  /// the filter is active: with Ember off this timer has nothing to verify.
  public static let healthCheckInterval: TimeInterval = 30
  public static let healthCheckTolerance: TimeInterval = 5

  /// Debounce for writing settings to disk. Deliberately longer than the
  /// transform coalescer: persistence is cheap to defer, pixels are not.
  public static let settingsPersistDelay: TimeInterval = 0.15
  public static let settingsPersistTolerance: TimeInterval = 0.05

  /// Transform coalescing during a continuous drag. This is a throttle, not a
  /// debounce: the first event of a burst schedules the write, so a long drag
  /// still updates the display ~20x/second instead of only on release.
  public static let transformCoalesceInterval: TimeInterval = 0.05
  public static let transformCoalesceTolerance: TimeInterval = 0.02

  /// Settling window after a display-topology event before reconciling.
  public static let topologySettleDelay: TimeInterval = 0.25
  public static let topologySettleDeadline: TimeInterval = 2.0

  /// Delay after wake before re-evaluating display state.
  public static let wakeReevaluationDelay: TimeInterval = 1.0

  /// Bounded window for repeated external-override detection.
  public static let overrideHistoryWindow: TimeInterval = 60
  /// Resets within the window that trip the bounded back-off.
  public static let overrideStrikeLimit = 3
  /// How long Ember stops re-applying after repeated external overrides.
  public static let overridePauseDuration: TimeInterval = 300
}
