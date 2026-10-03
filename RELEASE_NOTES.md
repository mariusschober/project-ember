# Project Ember 0.5.0 — Release integrity and direct-download readiness

<!-- Release owner: the Stage 2 UI/UX scope is written by that workstream's
     author and must be added before publishing. -->

0.5.0 is the release-engineering step between the 0.4.0 beta and a public
direct download, and it also fixes the correctness and energy defects found in
the 0.4.0 audit. The application's features are 0.4.0's; what changes is that
the build, the version, the licence and the documentation are now verifiable,
that a build Gatekeeper would reject can no longer be published by accident, and
that the panel no longer claims to be controlling a display that is not there.

## Correctness and honesty

- Displays that are unplugged are no longer reported as active. 0.4.0 kept them
  in the verified set, so the panel could read "Active on 1 display" with nothing
  connected and then accuse another display service of repeatedly resetting
  Ember's colour table — about a cable that had simply been removed.
- The "paused automatic reapplication" message is now backed by a real, bounded
  five-minute pause instead of a claim the app did not act on.
- A corrupt recovery journal no longer loses its warning on the next toggle, and
  Reset no longer reports success without touching a display.
- The journal's last-known-good copy is read: a torn write no longer downgrades
  an exact restore into a system colour reset while a valid record sits beside it.
- A display whose earlier restore could not be verified no longer blocks Ember
  from being switched on at all; its saved baseline is reused, never recaptured.
- Degenerate recovery records (one-sample or flat colour tables, empty display
  lists, impossible schema versions) are rejected instead of written to a panel.
- Backlight Lock refuses to engage hardware whose baseline it could not capture.
- While Ember is off, no repeating timer runs at all; a slider drag no longer
  rewrites the recovery journal, and the backlight guard polls every 30 s.

## Included

- **One version, one source.** `Sources/EmberCore/AppVersion.swift` is
  marketing 0.5.0 / build 5 and the only place the version is written. Both
  build scripts read it through `scripts/version.sh` and stamp the assembled
  `Info.plist`; `scripts/version.sh --check` fails on any disagreement and runs
  in CI.
- **Hard release gates.** `scripts/build-production-release.sh` asserts a
  `Developer ID Application` authority, `TeamIdentifier`, the Hardened Runtime
  flag, `codesign --verify --deep --strict`, `spctl --assess --type execute`
  acceptance, `stapler validate` on the DMG, an accepted DMG, and a mounted
  image that contains the app and the `/Applications` symlink with the app
  inside verifying. Every assertion fails the script; there are no `|| true`
  escapes left.
- **Hardened Runtime Location entitlement.**
  `com.apple.security.personal-information.location` is now in
  `Resources/ProjectEmber.entitlements`, which CoreLocation requires once the
  runtime is enabled. No App Sandbox entitlement: direct distribution only.
- **Local beta build tests what it ships.** `scripts/build-local-beta.sh` runs
  the unit tests in the same release tree, SDK and triple as the packaged
  binary, keeps stderr, verifies the ad-hoc signature and entitlements, checks
  the mounted DMG's contents, and writes a SHA-256.
- **Destructive self-tests are DEBUG-only.** `--system-self-test`,
  `--lifecycle-self-test`, `--prepare-crash-recovery-test` and `--recover-only`
  are compiled out of release builds; the shipped binary keeps the read-only
  `--system-probe` and refuses the others with an explanation and exit 64.
- **Proprietary licence.** `LICENSE` (copyright © 2026 Marius Schober, all
  rights reserved) grants use of the official unmodified binary and forbids
  redistribution or derivative distribution of the source. README, SECURITY
  and the bundle copyright notice agree with it.
- **Runbook and CI.** `docs/RELEASE_RUNBOOK.md` has the credentials, commands,
  download-verification steps and rollback procedure;
  `.github/workflows/release.yml` builds both configurations, tests, lints,
  assembles and gates — green without Apple credentials, strict with them.

## Not yet done (needs the owner's Apple credentials)

- No Developer ID-signed, notarized or stapled 0.5.0 DMG exists yet. Producing
  one requires an Apple Developer Program membership, a Developer ID
  Application certificate in the keychain, and a notarytool profile
  (`docs/RELEASE_RUNBOOK.md`). The scripts and CI will refuse to publish a bad
  artifact, but they cannot create the certificate.
- The §6.3 Location gate (enable Sun schedule on the *signed* build and confirm
  a fix arrives) cannot be reproduced with an ad-hoc bundle, because TCC
  decisions cannot be faked. It is scheduled as a release gate, not a footnote.

## Hardware verification status

Reversible physical tests were last executed on 2026-09-03 against the **0.4.0**
build (MacBook Pro M1 Pro, macOS 26.6.2, built-in Liquid Retina XDR + Dell
S2419H): read-only probe pass, gamma apply/restore pass, Pure Red pass,
Backlight Lock pass, automatic-brightness restore pass, journal cleared;
lifecycle pass; crash prepare + recovery pass. No 0.5.0 hardware run has been
claimed: 0.5.0 changes the backlight-guard interval and the timer scheduling
(`EmberTiming`), so those tests must be re-run from a DEBUG 0.5.0 build before
1.0 (`docs/TEST_PLAN.md`).

## Measured footprint (0.4.0, cited)

The public-release audit measured the long-running 0.4.0 build over a 62.07 h
window:

- Cumulative CPU: **1.019 s** user+system in 62.07 h = **0.00046 %** average
- Cumulative idle wake-ups: **9,838** in 62.07 h = **158.3 /h** (1 per 22.7 s),
  of which 61 in total were the expensive package-idle kind
- **Zero disk I/O while idle** (0 page-ins, 0 bytes read, 0 bytes written)

Two caveats, both from that audit: a currently unattributed ~3 s wake-up
cadence was live inside the process during the observation window, so the
audit's honest ceiling is higher than the cumulative average until that cadence
is attributed and removed — do not read 158/h as a bound on the current
process. And 0.5.0 changes the backlight-guard and health-check timers, so these
are a 0.4.0 measurement, not a 0.5.0 claim.

## Installing and verifying

Direct distribution only (Backlight Lock uses private DisplayServices).
Drag `Project Ember.app` from the DMG into `/Applications`. Verify a download
before opening it — `shasum -a 256`, `stapler validate`, `spctl`, `codesign` —
with the commands in `docs/RELEASE_RUNBOOK.md`.

## Rollback

The previous release stays downloadable. Quit Ember (which restores the
displays), verify and install the previous DMG over this one, and relaunch. The
settings and recovery journal are schema v2 in 0.4.0 and 0.5.0 alike
(`AppVersion.schemaVersion`), so the older build reads them unchanged; do not
delete the recovery journal by hand. Full procedure, including what to do if a
display looks wrong, is in `docs/RELEASE_RUNBOOK.md#rollback`.
