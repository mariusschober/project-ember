# Release runbook — Project Ember

Everything needed to build, verify, publish, and roll back a Project Ember
release. Version truth is `Sources/EmberCore/AppVersion.swift`; none of these
commands writes a version number by hand.

- [Credentials](#credentials)
- [Pre-flight](#pre-flight)
- [Local beta build](#local-beta-build)
- [Public release build](#public-release-build)
- [Verify a downloaded DMG](#verify-a-downloaded-dmg)
- [Publish](#publish)
- [Rollback](#rollback)
- [CI](#ci)

## Credentials

| Requirement | Needed for | How to check |
|---|---|---|
| Apple Developer Program membership | Developer ID signing, notarization | — |
| `Developer ID Application: Name (TEAMID)` certificate in the login keychain | `DEVELOPER_ID` | `security find-identity -v -p codesigning` |
| A stored notarytool keychain profile | `NOTARY_PROFILE` | `xcrun notarytool history --keychain-profile <profile>` |

Create the notary profile once, either with an app-specific password:

```bash
xcrun notarytool store-credentials "ember-notary" \
  --apple-id "you@example.com" --team-id "TEAMID" --password "<app-specific-password>"
```

or, preferred, with an App Store Connect API key:

```bash
xcrun notarytool store-credentials "ember-notary" \
  --key "AuthKey_XXXXXXXXXX.p8" --key-id "XXXXXXXXXX" --issuer "<issuer-uuid>"
```

The release script reads exactly two environment variables:

```bash
DEVELOPER_ID="Developer ID Application: Marius Schober (TEAMID)"
NOTARY_PROFILE="ember-notary"
```

No Apple credentials are needed to run the local beta build or the
`--verify-only` gate.

## Pre-flight

Run from the `ProjectEmber` folder. Every command must succeed; each one is
also what CI runs on every change.

```bash
scripts/version.sh --check                 # AppVersion.swift vs Info.plist vs scripts
swift build --disable-sandbox -c release   # release build
swift build --disable-sandbox              # debug build (and the only build with the
                                           #   destructive hardware self-tests)
swift test --disable-sandbox               # unit tests
./.build/release/EmberCoreChecks           # deterministic core checks
/usr/bin/plutil -lint Resources/Info.plist Resources/PrivacyInfo.xcprivacy Resources/ProjectEmber.entitlements
for script in scripts/*.sh; do bash -n "$script"; done
```

Hardware acceptance tests are destructive and DEBUG-only. Build the debug
binary, then run each mode on a test Mac that is not in active use (display
state is written for real):

```bash
swift build --disable-sandbox
./.build/debug/ProjectEmber --system-probe                 # read-only, also in release
./.build/debug/ProjectEmber --system-self-test             # apply / readback / restore
./.build/debug/ProjectEmber --lifecycle-self-test          # ~40 s with a 30 s guard
./.build/debug/ProjectEmber --prepare-crash-recovery-test
./.build/debug/ProjectEmber --recover-only
```

The shipped release binary exposes `--system-probe` only. Any other test flag
prints an explanation on stderr and exits 64 rather than mutating a display.

## Local beta build

Ad-hoc signed, for development and beta testing; no credentials.

```bash
scripts/build-local-beta.sh
```

Produces, under `def/outputs/`:

- `Project Ember.app` — ad-hoc signed, location entitlement included
- `Project-Ember-<version>-local-beta.dmg` — volume "Project Ember Beta" with
  the app and the `/Applications` symlink
- `Project-Ember-<version>-local-beta.sha256`

The script builds and tests in one release tree, then runs
`scripts/verify-release-artifacts.sh --expect adhoc` against both the bundle
and the mounted DMG. It fails on a bad signature, a missing entitlement, a
missing app or symlink in the image, or a version disagreement.

## Public release build

```bash
DEVELOPER_ID="Developer ID Application: Marius Schober (TEAMID)" \
NOTARY_PROFILE="ember-notary" \
scripts/build-production-release.sh
```

What the script does, in order — each step is a hard gate and there are no
`|| true` escapes:

1. release build, tests and `EmberCoreChecks` in the same tree;
2. `plutil -lint` on Info.plist, the privacy manifest and the entitlements;
3. bundle assembly with the version stamped from `AppVersion.swift`;
4. `codesign --force --options runtime --sign "$DEVELOPER_ID" --timestamp`;
5. pre-notarization gate on the app: `codesign --verify --deep --strict`,
   authority `Developer ID Application`, a `TeamIdentifier`, the `runtime` flag,
   and the location entitlement present. Gatekeeper is deliberately *not*
   asserted yet: a Developer ID app is only accepted once its notarization
   ticket exists;
6. DMG creation, `notarytool submit --wait`, `stapler staple`;
7. release gate on the DMG: `stapler validate`, `spctl --assess --type open`,
   the image mounts and contains `Project Ember.app` plus an `/Applications`
   symlink, and the app inside verifies, is Developer ID signed, is accepted by
   `spctl --assess --type execute`, and matches the stamped version;
8. SHA-256 written to `outputs/Project-Ember-<version>.sha256`.

A reviewer or CI can re-run only the gates against artifacts that already
exist, without credentials:

```bash
# full release expectations (app + stapled DMG)
scripts/build-production-release.sh --verify-only \
  "outputs/Project Ember.app" "outputs/Project-Ember-<version>.dmg"

# pre-notarization expectations only (app alone)
scripts/build-production-release.sh --verify-only "outputs/Project Ember.app"
```

Expect the full gate to fail on an ad-hoc build: that is the point of the gate.

Note on macOS versions: `spctl` lives in `/usr/sbin` (not `/usr/bin`) and is
deprecated from macOS 15.4 in favour of `syspolicy_check distribution`. The
gate finds `spctl` on `PATH` and falls back to `syspolicy_check distribution`;
if neither exists it fails rather than skipping the check.

## Verify a downloaded DMG

Replace `0.5.0` with the version you downloaded. The published
`Project-Ember-<version>.sha256` must match step 1 exactly.

```bash
# 1. Checksum
shasum -a 256 ~/Downloads/Project-Ember-0.5.0.dmg
cat Project-Ember-0.5.0.sha256

# 2. The disk image carries a stapled notarization ticket
xcrun stapler validate ~/Downloads/Project-Ember-0.5.0.dmg

# 3. Gatekeeper accepts the image
spctl --assess --type open --context context:primary-signature -vvv ~/Downloads/Project-Ember-0.5.0.dmg

# 4. The app inside is signed by the developer and verifies
hdiutil attach ~/Downloads/Project-Ember-0.5.0.dmg -nobrowse -readonly
codesign --verify --deep --strict --verbose=2 "/Volumes/Project Ember 0.5.0/Project Ember.app"
codesign -dv --verbose=4 "/Volumes/Project Ember 0.5.0/Project Ember.app" | grep -E "Authority|TeamIdentifier|flags"
spctl --assess --type execute -vvv "/Volumes/Project Ember 0.5.0/Project Ember.app"
hdiutil detach "/Volumes/Project Ember 0.5.0"
```

Expected: `Authority=Developer ID Application: …`, `TeamIdentifier=…`,
`flags=0x10000(runtime)`, and `spctl` printing `accepted`. If a step fails, do
not open the app; download it again from the official page and report the
failure. On macOS 15.4 or later `syspolicy_check distribution "/Volumes/…/Project
Ember.app"` is Apple's replacement for the `spctl` step and must also succeed.

## Publish

1. Build with the production script and keep both artifacts.
2. Upload `Project-Ember-<version>.dmg` and
   `Project-Ember-<version>.sha256` to the download page, replacing the
   previous version only after the new one verifies.
3. Publish `RELEASE_NOTES.md` for the version and the updated `CHANGELOG.md`.
4. Keep the previous DMG and its checksum downloadable (see Rollback).
5. Confirm `LICENSE` and the copyright notice in `Resources/Info.plist` still
   agree before announcing.

## Rollback

The previous release stays downloadable. Rolling back is replacing one app
bundle, not a migration:

1. Quit Project Ember from the panel (quit restores the displays). If a display
   looks wrong, open **Diagnostics… → Restore Display Now** first.
2. Download the previous DMG, verify it (previous section), drag
   `Project Ember.app` into `/Applications`, replacing the current copy.
3. Launch it. Settings and the recovery journal are schema v2 in 0.4.0 and
   0.5.0 alike (`AppVersion.schemaVersion` / `maxSupportedSchemaVersion`), so
   the older build reads them without a downgrade step. Do not delete the
   recovery journal by hand: the app recovers it on launch.
4. If a display still looks wrong, run **Restore Display Now** in the older
   build; it restores the per-display baselines captured before the transform.

For the maintainer: if 0.5.0 misbehaves in the field, stop linking the new DMG,
restore the previous DMG and checksum as the download, and only then
investigate. Re-run the production script after any fix; the release gate must
pass before the DMG is published again.

## CI

- `.github/workflows/ci.yml` runs on every push and pull request: version
  agreement, debug + release builds, tests, core checks, plist and script
  linting.
- `.github/workflows/release.yml` builds both configurations, then assembles a
  bundle and runs the artifact gates. Without repository secrets it uses the
  local beta path and additionally proves the release gate *rejects* an ad-hoc
  bundle. With the signing secrets present it imports a Developer ID identity
  and a notary API key and runs `scripts/build-production-release.sh`, so a bad
  signature fails the job.
- Required repository secrets for the signed path (never commit them):
  `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`,
  `DEVELOPER_ID_IDENTITY`, `NOTARY_API_KEY_P8_BASE64`, `NOTARY_API_KEY_ID`,
  `NOTARY_API_ISSUER_ID`.
