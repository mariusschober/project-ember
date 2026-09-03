import Foundation

// MARK: - Topology reconciliation model (0.4.0)
//
// Safety invariants encoded here (see also tests):
// 1. Journal before mutation.
// 2. Verified restore before deletion.
// 3. Immutable original baseline: transforms always derive from saved baseline.
// 4. No blanket restore on topology change.
// 5. Observed truth drives the UI.
// 6. Disconnected is pending, not forgotten.
// 7. Ambiguity means no mutation.
// 8. Backlight Lock is built-in-only and reversible.
// 9. A stale operation cannot win (generation binding).
// 10. No silent fallback.

/// Stable per-display topology entry. Identity — not transient CGDirectDisplayID —
/// is the reconciliation key.
public struct DisplayTopologyEntry: Equatable, Sendable, Hashable {
  public let identity: DisplayIdentity
  public let displayID: UInt32
  public let isOnline: Bool
  public let isActive: Bool
  public let isMirrored: Bool
  public let gammaCapacity: UInt32
  public let isBuiltIn: Bool

  public init(
    identity: DisplayIdentity,
    displayID: UInt32,
    isOnline: Bool = true,
    isActive: Bool = true,
    isMirrored: Bool = false,
    gammaCapacity: UInt32 = 256,
    isBuiltIn: Bool = false
  ) {
    self.identity = identity
    self.displayID = displayID
    self.isOnline = isOnline
    self.isActive = isActive
    self.isMirrored = isMirrored
    self.gammaCapacity = gammaCapacity
    self.isBuiltIn = isBuiltIn || identity.isBuiltIn
  }

  public var isGammaCompatible: Bool { gammaCapacity >= 2 && isOnline && isActive && !isMirrored }
  /// Backlight Lock target requires built-in identity; capability is checked separately.
  public var isBacklightCandidate: Bool { isBuiltIn && isGammaCompatible }
}

/// Point-in-time view of all enumerated displays, keyed by stable identity.
public struct DisplayTopologySnapshot: Equatable, Sendable {
  public let generation: UInt64
  public let capturedAt: Date
  public let entries: [DisplayTopologyEntry]

  public init(generation: UInt64, capturedAt: Date = Date(), entries: [DisplayTopologyEntry]) {
    self.generation = generation
    self.capturedAt = capturedAt
    self.entries = entries
  }

  /// Identity key used for set comparison. Prefers UUID, falls back to vendor/model/serial/unit.
  public func identityKeys() -> Set<String> {
    Set(entries.map { Self.key(for: $0.identity) })
  }

  public static func key(for identity: DisplayIdentity) -> String {
    if let uuid = identity.uuid, !uuid.isEmpty { return "uuid:\(uuid.lowercased())" }
    return
      "hw:\(identity.vendorNumber):\(identity.modelNumber):\(identity.serialNumber):\(identity.unitNumber):\(identity.isBuiltIn)"
  }

  /// Two snapshots match when they expose the same identity set with the same
  /// compatibility/built-in/mirror flags. Transient displayIDs are ignored.
  public func matchesTopology(of other: DisplayTopologySnapshot) -> Bool {
    let a = entries.sorted { key(of: $0) < key(of: $1) }
    let b = entries.sorted { key(of: $0) < key(of: $1) }
    guard a.count == b.count else { return false }
    for (x, y) in zip(a, b) {
      guard Self.key(for: x.identity) == Self.key(for: y.identity) else { return false }
      guard x.isOnline == y.isOnline, x.isActive == y.isActive,
        x.isMirrored == y.isMirrored,
        x.isGammaCompatible == y.isGammaCompatible,
        x.isBuiltIn == y.isBuiltIn
      else { return false }
    }
    return true
  }

  private func key(of entry: DisplayTopologyEntry) -> String {
    Self.key(for: entry.identity)
  }
}

/// Raw display-reconfiguration callback, preserved with flags (never discarded).
public struct DisplayReconfigurationEvent: Equatable, Sendable {
  public let displayID: UInt32
  public let flags: UInt32
  public let isBeginTransaction: Bool
  public let generation: UInt64
  public let timestamp: Date

  /// Decoded flag names for diagnostics (subset of CGDisplayChangeSummaryFlags).
  public var flagNames: [String] {
    var names: [String] = []
    if flags & 0x0000_0001 != 0 { names.append("BeginConfiguration") }
    if flags & 0x0000_0010 != 0 { names.append("Moved") }
    if flags & 0x0000_0020 != 0 { names.append("Enabled") }
    if flags & 0x0000_0040 != 0 { names.append("Disabled") }
    if flags & 0x0000_0080 != 0 { names.append("Mirror") }
    if flags & 0x0000_0100 != 0 { names.append("UnMirror") }
    if flags & 0x0000_0200 != 0 { names.append("DesktopShapeChanged") }
    if flags & 0x0000_0400 != 0 { names.append("Add") }
    if flags & 0x0000_0800 != 0 { names.append("Remove") }
    if flags & 0x0001_0000 != 0 { names.append("MainDisplayChanged") }
    if flags & 0x0002_0000 != 0 { names.append("MirrorChanged") }
    if names.isEmpty { names.append("Raw(0x\(String(flags, radix: 16)))") }
    return names
  }

  public init(
    displayID: UInt32,
    flags: UInt32,
    isBeginTransaction: Bool,
    generation: UInt64,
    timestamp: Date = Date()
  ) {
    self.displayID = displayID
    self.flags = flags
    self.generation = generation
    self.timestamp = timestamp
    self.isBeginTransaction = isBeginTransaction
  }
}

/// Per-identity reconciliation decision. Never restores an unchanged display.
public enum DisplayReconciliationAction: Equatable, Sendable {
  /// Leave untouched; transform already verified within tolerance.
  case leaveVerified(identity: DisplayIdentity)
  /// Reapply transform derived from saved baseline (OS reset detected).
  case reapplyFromBaseline(identity: DisplayIdentity)
  /// New display: journal baseline first, then apply + verify.
  case journalThenApply(identity: DisplayIdentity)
  /// Reconnected pending display: apply from canonical saved baseline (never recapture).
  case applyPendingBaseline(identity: DisplayIdentity)
  /// Restore saved baseline then remove entry only after verified restoration.
  case restoreSavedBaseline(identity: DisplayIdentity)
  /// Display offline: retain journal entry unchanged as pending.
  case retainPending(identity: DisplayIdentity)
  /// Leave untouched; count accurately in presentation.
  case leaveUnsupported(identity: DisplayIdentity, reason: String)
  /// Ambiguous identity: no mutation allowed.
  case leaveAmbiguous(reason: String)
}

public struct DisplayReconciliationPlan: Equatable, Sendable {
  public let generation: UInt64
  public let actions: [DisplayReconciliationAction]
  public let diagnosticWarning: String?

  public init(generation: UInt64, actions: [DisplayReconciliationAction], diagnosticWarning: String? = nil) {
    self.generation = generation
    self.actions = actions
    self.diagnosticWarning = diagnosticWarning
  }
}

public struct DisplayVerificationResult: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case verified
    case reappliedAndVerified
    case resetDetectedReapplyFailed(String)
    case applyFailed(String)
    case restoreFailed(String)
    case pendingOffline
    case unsupported(String)
    case ambiguous(String)
  }
  public let identityKey: String
  public let outcome: Outcome

  public init(identityKey: String, outcome: Outcome) {
    self.identityKey = identityKey
    self.outcome = outcome
  }
}

/// Pure, testable reconciliation planner.
/// - Parameters:
///   - snapshot: settled topology snapshot.
///   - journaled: currently journaled recovery entries (canonical baselines).
///   - controlled: identities Ember currently considers controlled+verified.
///   - desiredOn: whether Ember is desired on.
///   - ambiguityKeys: identity keys that match >1 online display (must not mutate).
public enum DisplayReconciler {
  public static func plan(
    snapshot: DisplayTopologySnapshot,
    journaled: [DisplayRecoveryEntry],
    controlled: Set<DisplayIdentity>,
    desiredOn: Bool,
    ambiguityKeys: Set<String> = []
  ) -> DisplayReconciliationPlan {
    var actions: [DisplayReconciliationAction] = []
    let controlledKeys = Set(controlled.map { DisplayTopologySnapshot.key(for: $0) })
    let journalByKey = Dictionary(
      grouping: journaled,
      by: { DisplayTopologySnapshot.key(for: $0.identity) }
    )
    let onlineByKey = Dictionary(
      grouping: snapshot.entries.filter(\.isOnline),
      by: { DisplayTopologySnapshot.key(for: $0.identity) }
    )

    // Ambiguous identities: explicit no-mutation action, never first-match.
    for key in ambiguityKeys {
      actions.append(.leaveAmbiguous(reason: "Identity \(key) matches multiple online displays; left untouched."))
    }

    if !desiredOn {
      // Desired off: restore every online journaled display; retain offline as pending.
      for entry in journaled {
        let key = DisplayTopologySnapshot.key(for: entry.identity)
        if ambiguityKeys.contains(key) { continue }
        if onlineByKey[key] != nil {
          actions.append(.restoreSavedBaseline(identity: entry.identity))
        } else {
          actions.append(.retainPending(identity: entry.identity))
        }
      }
      return DisplayReconciliationPlan(generation: snapshot.generation, actions: actions)
    }

    // Desired ON.
    for entry in snapshot.entries where entry.isOnline {
      let key = DisplayTopologySnapshot.key(for: entry.identity)
      if ambiguityKeys.contains(key) { continue }
      let journalEntries = journalByKey[key] ?? []
      if journalEntries.count > 1 {
        actions.append(.leaveAmbiguous(reason: "Multiple journal entries for \(key); manual resolution required."))
        continue
      }
      if !entry.isGammaCompatible {
        actions.append(.leaveUnsupported(identity: entry.identity, reason: "Display does not expose a writable gamma table."))
        continue
      }
      if let journaled = journalEntries.first {
        if controlledKeys.contains(key) {
          // Existing controlled display still online: verify, never blanket-restore.
          // Caller performs readback; planner requests verification path.
          actions.append(.reapplyFromBaseline(identity: journaled.identity))
        } else {
          // Reconnected pending display: canonical saved baseline.
          actions.append(.applyPendingBaseline(identity: journaled.identity))
        }
      } else {
        actions.append(.journalThenApply(identity: entry.identity))
      }
    }
    // Journaled but now offline → retain pending (never clear, never turn off others).
    for entry in journaled {
      let key = DisplayTopologySnapshot.key(for: entry.identity)
      if ambiguityKeys.contains(key) { continue }
      if onlineByKey[key] == nil {
        actions.append(.retainPending(identity: entry.identity))
      }
    }
    // Note: caller distinguishes leaveVerified vs reapply after readback within
    // tolerance; planner emits reapplyFromBaseline as "verify-then-maybe-reapply"
    // to keep the pure function small. Coordinator maps verified → no I/O.
    return DisplayReconciliationPlan(generation: snapshot.generation, actions: actions)
  }
}
