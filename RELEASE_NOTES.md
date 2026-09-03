# Project Ember 0.4.0 — Reliability, UX, and Release Hardening

Release candidate for personal use and direct beta. Not 1.0: 1.0 requires the
hardware acceptance matrix plus Developer ID-signed, notarized artifacts.

## Included

- Generation-based topology reconciliation (no app-initiated neutral flash on
  unchanged displays; verified readback drives the UI).
- Fail-safe journaling with quarantine/backup, verified restores, and safe
  legacy handling.
- Desired/observed/presentation separation with truthful counts and attention
  states (Retry/Reset, Copy/Export Diagnostics).
- Built-in-only reversible Backlight Lock with read-before-write guard and
  retained preference.
- Menu-bar click behavior (Open Controls default; Toggle Ember optional;
  right-click always opens controls).
- Sun schedule hardening and structured solar presentation.
- AppKit refinements, contrast/accessibility fixes, mechanism-based copy.
- `EmberCoreTests` (36 tests) + `EmberCoreChecks`; CI; local + production
  build scripts.
- Privacy: on-device approximate location/settings; no analytics/networking.

## Manual hardware verification (this release)

No hardware-mutating self-tests were run in CI (fakes only). Reversible
physical tests require an explicitly available test Mac with a safe recovery
path. Exact manual commands:

```
ProjectEmber --system-probe
ProjectEmber --system-self-test        # reversible; journaled, verified, restored
ProjectEmber --lifecycle-self-test     # live updates, guard, reconfig, sleep/wake
ProjectEmber --prepare-crash-recovery-test && ProjectEmber --recover-only
```

Status on this build machine: **unexecuted** (no test Mac was explicitly made
available during implementation). Do not claim the acceptance matrix passed.
See the final engineering report for what was and was not verified.

## Known distribution limitation

Local builds are ad-hoc signed. Public beta requires
`scripts/build-production-release.sh` with a Developer ID Application identity
and notarytool profile (Hardened Runtime, timestamp, submit/staple/validate,
DMG smoke-check, SHA-256).

## Known limitations

Private DisplayServices use; external-display timing; spectral variability;
software-dimming banding; no PWM measurement. No explicit license yet — owner
decision required before public 1.0 (see SECURITY.md).
