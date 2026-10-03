# Changelog

## 0.5.0 — Release integrity and direct-download readiness (2026-10-03)

<!-- Release owner: the Stage 2 UI/UX bullets are written by that workstream's
     author and must be added before publishing. -->

- **The app no longer over-reports what it controls.** Unplugging a display left
  it in the "verified" set, so the panel kept reporting "Active on 1 display"
  with nothing connected — and the 30 s verification pass then read the missing
  table as an external reset, raising a red "another display service keeps
  replacing Ember's colour table" accusation about a removed cable. Verified,
  failed and controlled display sets are now scoped to the settled topology, and
  a display that no longer resolves to a target is skipped instead of counted as
  an override.
- **The promised pause is a real pause.** The old message claimed Ember "paused
  automatic reapplication" while the timer kept re-applying. Three detected
  overrides inside 60 s now arm a bounded five-minute pause with honest copy,
  and Retry or Reset ends it immediately.
- **Journal-integrity warnings survive.** A corrupt journal raised the correct
  error and then lost it on the next toggle, because an empty work list was
  treated as "everything restored" in three separate places. Such warnings are
  now sticky until the user Retries or Resets, and Reset always attempts the
  system colour fallback when there is no record — previously it reported
  "Manual display reset completed" without touching a display.
- **The last-known-good journal copy is finally read.** It was written on every
  save and never consulted, so one torn write downgraded an exact restore into a
  system colour reset even when a valid record sat beside it.
- **A stuck baseline can no longer make Ember impossible to switch on.** A
  display whose earlier restore never verified used to block activation; its
  saved baseline is now reused rather than recaptured, so the original stays
  recoverable and Ember still turns on.
- **Degenerate recovery records can no longer be written to a panel.** A
  one-sample or flat table decodes as valid JSON but resamples to a constant
  colour; such records, empty display lists and schema versions below 1 are now
  treated as corrupt.
- **Backlight Lock refuses hardware it could not restore.** It used to proceed
  after a failed baseline capture, disabling automatic brightness and pinning the
  backlight with nothing journaled to undo it.
- **Less work while idle.** The health timer exists only while Ember is on (it
  used to wake the app 120×/hour to return immediately), a slider flush no longer
  rewrites the ~33 KB recovery journal, a continuous drag applies ~20×/second
  instead of freezing until release, and the backlight guard polls every 30 s
  instead of 5 s.
- **Testable orchestration.** `DisplayCoordinator` takes injectable display,
  backlight, journal, settings and login-item seams, so the shipped logic is
  covered by tests rather than only by a destructive hardware self-test, and the
  policy helpers the tests already covered are now the ones production calls.

Release-engineering release. The reason for it is that the artifact pipeline
could previously report success for a build Gatekeeper would reject; that is no
longer possible, and the version, the licence, and the documentation now match
what is shipped.

- **Single version truth.** `EmberCore.AppVersion` is the only place the
  version is written down (0.5.0, build 5). `scripts/version.sh` parses it, both
  build scripts derive their artifact names from it and stamp the assembled
  `Info.plist` with it, and `scripts/version.sh --check` fails if
  `Resources/Info.plist`, a built bundle, or a script pins a different number.
  CI runs that check on every push.
- **Release gates that fail the build.** `build-production-release.sh` no longer
  ends its checks in `|| true`. It asserts a `Developer ID Application`
  authority, a `TeamIdentifier`, the `runtime` flag, `codesign --verify
  --deep --strict`, `spctl --assess --type execute` acceptance, `stapler
  validate` on the DMG, `spctl` acceptance of the image, the mounted image
  containing `Project Ember.app` plus the `/Applications` symlink, and the app
  inside the image verifying at the stamped version. A new credential-free
  reviewer entry point (`--verify-only <app> [<dmg>]`) re-runs the same gate,
  and the assertions live in `scripts/verify-release-artifacts.sh` so CI uses
  exactly the same code.
- **Hardened Runtime Location entitlement.** The signed build now carries
  `com.apple.security.personal-information.location`, which CoreLocation
  requires once Hardened Runtime is enabled. Without it the Sun schedule would
  silently never receive a fix in the build users install, while the ad-hoc
  developer build appeared to work. No App Sandbox entitlement is added:
  Project Ember is a direct download.
- **The beta script tests what it ships.** `build-local-beta.sh` runs the unit
  tests in the same release build tree, SDK and triple as the binary it
  packages, stops discarding stderr, drops the unexplained `--jobs 1`, resolves
  the product directory with `--show-bin-path` (the 0.4.0 hardcoded path no
  longer matches SwiftPM's layout), verifies the signature and entitlements,
  mounts the finished DMG and checks its contents, and writes a SHA-256 file.
- **Destructive hardware self-tests compile out of release builds.** The
  `--prepare-crash-recovery-test`, `--recover-only`, `--lifecycle-self-test`
  and `--system-self-test` modes write real gamma/backlight state and the
  production recovery journal, so they now exist only in DEBUG builds. The
  shipped binary keeps the read-only `--system-probe`, and a release build
  answers any destructive flag with one line on stderr and exit 64 instead of
  mutating a display or silently launching. `--lifecycle-self-test` waits on
  `EmberCore.EmberTiming.backlightGuardInterval` instead of a hardcoded 6.5 s.
- **Proprietary licence.** `LICENSE` added: copyright © 2026 Marius Schober,
  all rights reserved, with a plain-language grant to use the official
  unmodified binary and an explicit no-redistribution/no-derivative clause for
  the source. README, SECURITY and the `Info.plist` copyright notice now say
  the same thing; the "no explicit licence yet" language is gone.
- **Release runbook and CI.** `docs/RELEASE_RUNBOOK.md` documents the required
  Apple credentials, the exact publish commands, how to verify a downloaded
  DMG, and the rollback procedure. `.github/workflows/release.yml` builds both
  configurations, runs tests and core checks, lints metadata, assembles the
  bundle and runs the artifact gates — proving without credentials that the
  release gate rejects an ad-hoc bundle, and running the real signed path when
  the signing secrets exist.

See `docs/RELEASE_RUNBOOK.md` for the release procedure and `RELEASE_NOTES.md`
for scope.

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
- AppKit refinements: fitted no-scroll panel (fixed 390pt width, no scroll
  view), hero orb as the panel on/off control with capped hover preview and
  subtle power glyph, full-width settings card rows on a shared grid,
  constraint-pinned preset highlight, fixed three-stop slider gradient with
  fully visible thumbs at 0%/100%, consolidated switch path, cached status
  images, Reduce Motion/Transparency/Contrast handling, contrast-raised text
  tokens, footer author link (mariusschober.com), and mechanism-based copy.
  Layout is deterministic: static wrap widths, explicit row widths, and no
  width↔wrap feedback loops (see `docs/SYSTEM_DESIGN.md`).
- Standard `EmberCoreTests` suite plus `EmberCoreChecks` smoke checks;
  CI on macOS runners; local ad-hoc script plus production
  sign/notarize/staple/verify script.
- Version truth centralized in `EmberCore.AppVersion` (0.4.0, build 4).

See `AUDIT_FIXES.md` for the per-issue map and `RELEASE_NOTES.md` for scope.
