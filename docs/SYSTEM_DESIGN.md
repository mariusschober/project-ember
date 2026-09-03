# System design (0.4.0)

## Version truth

`EmberCore.AppVersion` (marketing 0.4.0, build 4, schema 2) is the single
source of truth. Info.plist, artifact names, and fallback UI derive from it.

## Topology reconciliation (replaces full restore/reapply)

`DisplayReconfigurationObserver` emits an event stream: affected
`CGDirectDisplayID`, complete flags, begin/end transaction, monotonic local
generation, timestamp. Flags are decoded for diagnostics and never discarded.
`NSApplication.didChangeScreenParametersNotification` is a complementary
main-thread settling signal; CoreGraphics flags remain authoritative.

Value types: `DisplayTopologySnapshot`, `DisplayTopologyEntry`,
`DisplayReconfigurationEvent`, `DisplayReconciliationPlan`,
`DisplayVerificationResult`. Snapshots key on stable identity (UUID, else
vendor/model/serial/unit + built-in), not transient IDs, and track
online/active/mirrored/gamma-compatible/built-in states.

Settling by generation (cancellable Swift concurrency, MainActor-owned):

1. Begin event: increment generation, mark reconciling, no restore.
2. End: sample immediately, then after ~250 ms debounce.
3. Reconcile when two consecutive identity snapshots match and no newer
   generation arrived.
4. Bound at 2 s; on timeout reconcile the latest safe snapshot with a
   diagnostic warning.
5. Every delayed task checks its captured generation before I/O or publish
   (stale operations cannot win).

While desired ON, per identity:

- Still-online controlled: never restore or recapture; read back; leave
  untouched within tolerance, else reapply from the saved immutable baseline.
- Disconnected: remove from online set, retain journal entry unchanged as
  pending, keep remaining displays on.
- New with no entry: unique identity, capture baseline, capture hardware state
  on verified built-in Backlight Lock targets, journal before mutation, apply
  + verify, mark controlled only after verification. On apply failure, restore
  and verify the captured baseline; retain entry if rollback unproven.
- Reconnected pending: canonical saved baseline (never overwrite), derive
  transform, apply + verify (no app-induced neutral flash). If desired off,
  restore and remove only after verification.
- Unsupported/ambiguous: untouched, accurately counted; ambiguity returns an
  explicit recoverable error, never first-match.

Post-reconciliation verification while desired on: immediate, ~0.5 s, ~2 s
(generation-bound, cancellable; one bounded reapply on reset + re-verify).
Sparse 30 s read-only health check with timer tolerance; bounded recovery on
drift; 3 overrides in 60 s enter a truthful degraded attention state with
Retry/Reset and identity/timing context.

Test seams (`DisplayProtocols.swift`): enumerator, gamma, backlight, journal,
settings, clock — only enough indirection for deterministic fakes.

## Color pipeline

Warmth 0–82% maps through a CIE daylight approximation from 6500 K to 2000 K
(xyy → linear sRGB gains). Final 18% interpolates to red-channel-only Pure Red
(not a color temperature). Software brightness multiplies transformed channels.
Original tables are immutable; slider changes never compound. Gamma tables
cannot mix channels into grayscale/E-Ink.

## Backlight Lock (built-in-only, reversible)

Runtime-loads DisplayServices; capability requires built-in identity plus
read/write symbols. Captures hardware brightness + automatic-brightness only
when reads succeed; changes automatic brightness only when captured.
Preference (`settings.backlightLockEnabled`) is separate from engagement
(engaged/unavailable/failed). Off/sunrise/quick-off/sleep/termination restore
hardware but preserve preference; only explicit user-off or emergency reset
clears it. Guard polls at 5 s (1 s tolerance), reads before writing, writes
only on drift (<0.97 or ambient re-enabled), verifies after writes, retries
unavailable targets during reconciliation. Copy never claims PWM elimination.

## Recovery and lifecycle

States: off, activating, active, reconciling, restoring, suspended, degraded.
`DisplayStateMachine` owns transitions including degraded→sleep→suspended and
topology-during-activation/restore; coordinator executes returned actions
(verify/publish) rather than ignoring them.

Journal at `~/Library/Application Support/Project Ember/display-recovery-v1.json`
(schema v2 array; v1 migration preserved; future schemas rejected). Explicit
`JournalLoadOutcome` (absent/loaded/future/corrupt/I-O). Corrupt journals are
quarantined with a last-resort ColorSync reset and explicit attention — never
treated as empty. Last-known-good backup updated atomically. Per-display
`RestoreOutcome` (verified/pending/ambiguous/write-fail/readback/hardware
failures); unsuccessful entries stay journaled. `restoreVerified` reads back
within 0.004 (gamma) and verifies hardware when captured. ColorSync fallback
prunes only entries actually present within tolerance. Safety invariants
(journal-before-mutation, verified-restore-before-deletion, immutable baseline,
no blanket restore, observed truth, pending-not-forgotten, ambiguity-no-mutation,
built-in-only reversible backlight, generation binding, no silent fallback) are
encoded in code comments and tests.

Disable/sleep/quit/manual reset restore every available entry; absent entries
stay pending and retry before that display can be re-transformed.

## Desired / observed / presentation

`EmberPresentation` (desired flag, operation state, observed-active bool,
counts, attention, titles) is the single render source. Active requires ≥1
verified transform on an intended online display. Pending-only uses calm
truthful copy; real failures surface Retry/Reset.

## Sun schedule

`SolarScheduleController` uses one-shot `requestLocation()` only, validates
`location.timestamp` age (≤5 min), rounds to 0.1°, stores locally. Transition
and retry timers are independent; cached-failure scheduling continues from
cache plus a future retry; retry cancels only on fresh success or disable.
Exposes schedule + authorization + refreshing + error for structured UI (no
string parsing). Enabling also enables Launch at Login (explicit copy).
Preference retained on transient failures; denied/restricted turns off with
explanation. NOAA model, 90.833° zenith, local zone/DST, polar-safe forward
search.

## Privacy and permissions

Only the location purpose string is declared. No networking, background
location, telemetry, or accounts. Coordinates never leave the Mac.

## Panel layout (deterministic, no scroll)

The control panel is a fitted 390pt popover with no scroll view. Layout rules
that keep it deterministic:

- Static wrapping widths (`EmberMetrics.rowTextWidth` 244, `heroTextWidth`
  198). Deriving wrap widths from bounds at layout time creates a width↔wrap
  feedback loop that staggers rows, stretches icons, and grows the window.
- Settings-card rows pin full card width; toggle/behavior/slider icons share
  one grid (`rowLeadingInset`, `rowIconWidth`, `rowIconTextGap`).
- Row icons live in fixed-size boxes; glyphs letterbox inside instead of
  fighting symbol aspect constraints.
- The hero orb is the panel's on/off control (hover previews the result with
  a capped mix, hand cursor, tooltips, focus ring, VoiceOver button
  semantics); the header is static branding. A subtle power glyph marks the
  orb; it never pulses and ignores clicks.
- Footer fits by construction: full claim sentence, author link
  (https://mariusschober.com/), single BETA badge. Footers wider than budget
  grow the whole window — measure after copy changes.
