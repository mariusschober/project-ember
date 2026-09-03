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
- AppKit refinements: fitted no-scroll panel, hero orb on/off control with
  hover preview, full-width settings rows, constraint-pinned preset highlight,
  contrast/accessibility fixes, footer author link, mechanism-based copy.
- `EmberCoreTests` (36 tests) + `EmberCoreChecks`; CI; local + production
  build scripts.
- Privacy: on-device approximate location/settings; no analytics/networking.

## Hardware verification (this release)

Reversible physical tests were executed 2026-09-03 on MacBook Pro (M1 Pro,
macOS 26.6.2) with built-in Liquid Retina XDR + Dell S2419H external:

```
ProjectEmber --system-probe               # pass: 2/2 compatible, 1024 samples,
                                          # backlight control on built-in only
ProjectEmber --system-self-test           # pass: gamma apply/restore, Pure Red,
                                          # Backlight Lock, auto-brightness restore,
                                          # journal cleared
ProjectEmber --lifecycle-self-test        # pass: live updates, backlight guard,
                                          # reconfig, sleep/wake/termination restores
ProjectEmber --prepare-crash-recovery-test && ProjectEmber --recover-only
                                          # pass: startup recovery verified,
                                          # journal cleared
```

Not performed: the full acceptance matrix (20× HDMI/USB-C hot-plug cycles,
VoiceOver/keyboard/a11y pass, 8-hour idle observation, etc.). Do not claim
1.0 readiness until that matrix passes on real hardware plus Developer ID
signing/notarization.

## Known distribution limitation

Local builds are ad-hoc signed. Public beta requires
`scripts/build-production-release.sh` with a Developer ID Application identity
and notarytool profile (Hardened Runtime, timestamp, submit/staple/validate,
DMG smoke-check, SHA-256).

## Known limitations

Private DisplayServices use; external-display timing; spectral variability;
software-dimming banding; no PWM measurement. No explicit license yet — owner
decision required before public 1.0 (see SECURITY.md).
