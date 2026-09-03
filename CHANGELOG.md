# Changelog

## 0.4.0 — Reliability, UX, and Release Hardening (2026-09-03)

Reliability and interaction release. Not 1.0: 1.0 waits for the HDMI/topology
acceptance matrix on real hardware plus Developer ID-signed, notarized public
artifacts.

- Replaces full restore/reapply on display changes with generation-based
  topology reconciliation. Unchanged displays are never blanket-restored;
  transforms are verified by readback and reapplied only on detected OS resets.
- Generation-bound settling (immediate + 250 ms debounce, 2 s bound), post-event
  verification at ~0.5 s and ~2 s, sparse 30 s health checks, and bounded
  degraded state after 3 overrides in 60 s.
- Fail-safe recovery journal: explicit load outcomes, quarantine on corruption,
  last-known-good backup, future-schema rejection, per-display verified restore,
  failed-rollback retention, and ColorSync fallback that prunes only matching
  entries. Legacy v1 built-in records never resolve to unrelated externals.
- Desired/observed/presentation separation: UI shows active only on verified
  readback, with verified/unsupported/pending/failed counts and calm
  pending-only copy.
- Backlight Lock is built-in-only, read-before-write, preference-vs-engagement
  separated, and uses accurate non-PWM product language. Software brightness
  naming throughout.
- Menu-bar primary-click setting (`openControls` default for 0.3.0 upgrades,
  `toggleEmber` optional). Right-click always opens controls. Busy coalescing,
  haptics, and dynamic accessibility labels.
- Sun schedule hardening: location-age validation, independent
  transition/retry timers, cached-failure retry, structured solar presentation,
  and retained preference on transient failures.
- AppKit refinements: real scroll view, title-aligned toggle rows, fixed
  three-stop slider gradient, consolidated switch path, cached status images,
  Reduce Motion/Transparency/Contrast handling, contrast-raised text tokens,
  and mechanism-based copy.
- Standard `EmberCoreTests` suite (36 tests) plus `EmberCoreChecks` smoke checks;
  CI on macOS runners; local ad-hoc script plus production
  sign/notarize/staple/verify script.
- Version truth centralized in `EmberCore.AppVersion` (0.4.0, build 4).

See `AUDIT_FIXES.md` for the per-issue map and `RELEASE_NOTES.md` for scope.
