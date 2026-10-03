# Verification plan (0.5.0)

## Deterministic tests (`swift test`, no hardware mutation)

`EmberCoreTests` (36 tests, Swift Testing) plus `EmberCoreChecks` smoke checks:

- Topology: zero restores to survivor on unplug, disconnect retains entry,
  journal-then-apply for new displays, pending uses saved baseline, duplicate
  coalescing, transient-ID tolerance, stale-generation rejection, ambiguous
  no-mutation, activation/restore convergence, OS-reset delta detection,
  3-in-60s degraded threshold.
- Recovery: corrupt≠absent + quarantine, empty retained, future-schema
  rejection, v1 migration, mismatch retention, failed-rollback retention,
  offline pending, legacy built-in never resolves to external.
- Backlight: external never candidate, no write when correct, drift signals
  bounded write.
- State/presentation: failed≠active, pending calm, degraded surfaced,
  degraded→sleep→suspended, counts, exhaustive transitions.
- Settings/menu: 0.3.0 decodes to openControls, primary routing, right-click
  always opens, busy coalescing.
- Solar/UI: custom clears preset, stale rejected, DST/polar correctness.
- Core checks: neutral/Kelvin/Pure Red, gamma composition/resample/zero-drift,
  journal-before-apply + restore-before-clear ordering, identity matching,
  settings migration/override expiry, journal round-trip, solar equinox/polar/
  time-zone/DST.

## Read-only system probe

`ProjectEmber --system-probe` enumerates active de-duplicated displays: ID,
UUID, built-in, gamma capacity/readability, hardware capability. No writes.
This is the only test mode in the shipped release binary.

## Reversible system checks (DEBUG build only, explicit test Mac, never unattended CI)

The destructive modes — `--system-self-test`, `--lifecycle-self-test`,
`--prepare-crash-recovery-test` + `--recover-only` — write real gamma and
backlight state and the production recovery journal, so they are compiled out
of release builds (audit REL-1). Build the debug binary first:

```bash
swift build --disable-sandbox
./.build/debug/ProjectEmber --system-self-test
./.build/debug/ProjectEmber --lifecycle-self-test          # waits one full
                                                           #   EmberTiming.backlightGuardInterval
./.build/debug/ProjectEmber --prepare-crash-recovery-test
./.build/debug/ProjectEmber --recover-only
```

The release binary answers any of those flags with one line on stderr and exit
64. CI runs only fakes.

Recorded run (2026-09-03, **0.4.0**, MacBook Pro M1 Pro, macOS 26.6.2,
built-in Liquid Retina XDR + Dell S2419H): probe pass (2/2 compatible, 1024
samples, backlight on built-in only); system self-test pass (apply/restore,
Pure Red, Backlight Lock, auto-brightness restore, journal cleared); lifecycle
pass (live updates, guard, reconfig, sleep/wake/termination); crash prepare +
recover pass (startup recovery verified, journal cleared). 0.5.0 changes the
backlight guard interval and the coordinator's timer scheduling, so these
hardware checks must be re-run on a debug 0.5.0 build before 1.0.

## Manual hardware acceptance matrix (required for 1.0, not claimed for 0.5.0)

Record Mac model, macOS version, connection type, display make/model,
HDR/True Tone/Night Shift state, and result for each:

1. Built-in only: on/off, presets, custom warmth, software brightness,
   Backlight Lock, sleep/wake, quit/relaunch, crash recovery.
2. Built-in + HDMI external: 20 unplug/replug cycles while active.
3. Built-in + USB-C/DisplayPort external: 20 unplug/replug or power cycles.
4. Disconnect external while dragging a slider.
5. Connect/disconnect during activation, restoration, wake, solar transition.
6. Reconnect a display with a pending baseline.
7. Resolution/refresh/rotation/HDR/mirror/clamshell/display-power changes.
8. True Tone/Night Shift/auto-brightness/brightness-key interactions.
9. Quit/force-kill with one display disconnected, reconnect, verify pending restore.
10. Right/secondary click and both primary-click modes.
11. VoiceOver, Full Keyboard Access, Increase Contrast, Reduce Transparency,
    Reduce Motion, Differentiate Without Color.
12. Eight-hour idle with popover closed; verify no orb loop and low wakeups.

Pass conditions: no Ember-initiated restore of unchanged built-in on peer
changes; no baseline deleted before verified restoration; post-cycle intended
displays stay verified ≥10 min; OS overrides detected (never falsely active);
repeated conflicts become bounded attention; off restores exactly with pending
retained; clicks behave per setting; Sun row alignment stable; custom values
leave no stale highlight; artifacts signed/notarized/stapled with checksums.

## Release checks

- `swift test` and `EmberCoreChecks` pass (tests run in the release tree)
- `scripts/version.sh --check` — AppVersion.swift, Info.plist, the assembled
  bundle and the scripts all agree
- Read-only probe reports current displays
- arm64 Mach-O, macOS 14 minimum, Info.plist 0.5.0 + copyright
- Privacy manifest valid, no collected/tracking data
- Entitlements contain exactly the Hardened Runtime location entitlement
- Local ad-hoc signature verifies; production path signs/notarizes/staples
- DMG mounts with app + Applications shortcut; fresh launch leaves filter and
  Sun schedule off
- Hard gates: `scripts/verify-release-artifacts.sh --expect release` accepts the
  signed app and DMG (and rejects an ad-hoc bundle)
