#!/bin/bash
#
# Production Developer ID-signed + notarized release path for Project Ember.
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="ember-notary" \
#   scripts/build-production-release.sh
#
#   scripts/build-production-release.sh --verify-only <app> [<dmg>]
#     Runs only the release gate against artifacts that already exist (used by
#     a reviewer or by CI when the build already happened). Requires no Apple
#     credentials and does not build, sign, or upload anything. With a DMG it
#     applies the full release expectations; with only an app it applies the
#     pre-notarization ("signed") expectations.
#
# Required Apple credentials (full runbook: docs/RELEASE_RUNBOOK.md):
#   * Apple Developer Program membership with a "Developer ID Application"
#     certificate in the login keychain; DEVELOPER_ID names it exactly as
#     `security find-identity -v -p codesigning` prints it.
#   * A stored notarytool keychain profile named by NOTARY_PROFILE, created once:
#       xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#         --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#     or with an App Store Connect API key:
#       xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#         --key AuthKey_XXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
#
# Every step is a hard gate: the script exits non-zero if the signature is not a
# Developer ID signature with the Hardened Runtime flag, if codesign --verify
# fails, if Gatekeeper rejects the app or the DMG, if the notarization ticket is
# not stapled, or if the mounted DMG is missing the app or the /Applications
# symlink. No gate failure is ever swallowed (Stage 0.2).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="$(cd "${ROOT_DIR}/.." && pwd)"

# --verify-only runs the release gate against existing artifacts; it needs no
# credentials and touches nothing.
if [[ "${1:-}" == "--verify-only" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "usage: $0 --verify-only <app> [<dmg>]" >&2
    exit 2
  fi
  VERIFY_ARGS=(--expect signed --app "$2")
  if [[ $# -ge 3 ]]; then
    VERIFY_ARGS=(--expect release --app "$2" --dmg "$3")
  fi
  exec /bin/bash "${ROOT_DIR}/scripts/verify-release-artifacts.sh" "${VERIFY_ARGS[@]}"
fi

: "${DEVELOPER_ID:?set DEVELOPER_ID to your 'Developer ID Application: …' identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a stored notarytool profile}"

# Fail before a multi-minute build if the identity obviously cannot be a
# Developer ID Application certificate.
case "${DEVELOPER_ID}" in
  "Developer ID Application: "*) ;;
  *)
    echo "error: DEVELOPER_ID must name a 'Developer ID Application: …' identity (got: ${DEVELOPER_ID})." >&2
    echo "       List yours with: security find-identity -v -p codesigning" >&2
    exit 1
    ;;
esac

# Version truth is Sources/EmberCore/AppVersion.swift; never write it here.
VERSION="$(/bin/bash "${ROOT_DIR}/scripts/version.sh" --marketing)"
BUILD_NUMBER="$(/bin/bash "${ROOT_DIR}/scripts/version.sh" --build)"

SDK="$(xcrun --show-sdk-path)" || {
  echo "error: xcrun --show-sdk-path failed; install the Xcode command line tools." >&2
  exit 1
}
if [[ -z "${SDK}" || ! -d "${SDK}" ]]; then
  echo "error: could not discover the macOS SDK via xcrun." >&2
  exit 1
fi
BUILD_DIR="/private/tmp/ProjectEmberRelease-${UID}"
CACHE_DIR="/private/tmp/ProjectEmberReleaseCache-${UID}"
OUTPUT_DIR="${WORKSPACE_DIR}/outputs"
STAGE_DIR="/private/tmp/ProjectEmberStage-${UID}"
APP_PATH="${STAGE_DIR}/Project Ember.app"
DMG_PATH="${OUTPUT_DIR}/Project-Ember-${VERSION}.dmg"
CHECKSUM_PATH="${OUTPUT_DIR}/Project-Ember-${VERSION}.sha256"

cleanup() {
  rm -rf "${STAGE_DIR}/dmg" "${BUILD_DIR}"
}
trap 'cleanup' EXIT
trap 'rm -rf "${STAGE_DIR}/dmg" "${BUILD_DIR}"; exit 1' INT TERM

# Clean staging before use and on failure.
rm -rf "${STAGE_DIR}" "${BUILD_DIR}"
mkdir -p "${STAGE_DIR}/dmg" "${OUTPUT_DIR}" "${CACHE_DIR}/cache" "${CACHE_DIR}/config" "${CACHE_DIR}/security"

echo "SDK: ${SDK}"
echo "Version: ${VERSION} build ${BUILD_NUMBER} (arm64 Apple Silicon; see README for the product decision)"

export SDKROOT="${SDK}"
# Keep every compiler cache inside CACHE_DIR. Without these, SwiftPM's manifest
# compile and clang's module cache fall back to the per-user locations, which
# restricted environments cannot write to (the build then fails before it even
# reaches the build plan).
export CLANG_MODULE_CACHE_PATH="${CACHE_DIR}/clang"
export SWIFT_MODULE_CACHE_PATH="${CACHE_DIR}/swift"

SWIFT_FLAGS=(
  --disable-sandbox
  --cache-path "${CACHE_DIR}/cache"
  --config-path "${CACHE_DIR}/config"
  --security-path "${CACHE_DIR}/security"
  --sdk "${SDK}"
  --triple arm64-apple-macosx14.0
  --build-path "${BUILD_DIR}"
)

swift build --configuration release "${SWIFT_FLAGS[@]}"
# Same release configuration and the same build tree as the shipped binary.
swift test --configuration release "${SWIFT_FLAGS[@]}"

# Resolve the product directory from SwiftPM instead of assuming a layout.
RELEASE_DIR="$(swift build --configuration release "${SWIFT_FLAGS[@]}" --show-bin-path)"
[[ -x "${RELEASE_DIR}/ProjectEmber" ]] ||
  { echo "error: no release binary at ${RELEASE_DIR}/ProjectEmber" >&2; exit 1; }
[[ -x "${RELEASE_DIR}/EmberCoreChecks" ]] ||
  { echo "error: no EmberCoreChecks at ${RELEASE_DIR}/EmberCoreChecks" >&2; exit 1; }

"${RELEASE_DIR}/EmberCoreChecks"
/usr/bin/plutil -lint "${ROOT_DIR}/Resources/Info.plist" "${ROOT_DIR}/Resources/PrivacyInfo.xcprivacy"
/usr/bin/plutil -lint "${ROOT_DIR}/Resources/ProjectEmber.entitlements"

# Assemble the bundle reproducibly.
CONTENTS="${APP_PATH}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
/usr/bin/install -m 755 "${RELEASE_DIR}/ProjectEmber" "${MACOS_DIR}/ProjectEmber"
/usr/bin/install -m 644 "${ROOT_DIR}/Resources/Info.plist" "${CONTENTS}/Info.plist"
# Stamp the version from AppVersion.swift so the bundle can never disagree with
# the code it contains (Stage 0.4).
/usr/bin/plutil -replace CFBundleShortVersionString -string "${VERSION}" "${CONTENTS}/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "${BUILD_NUMBER}" "${CONTENTS}/Info.plist"
/usr/bin/install -m 644 "${ROOT_DIR}/Resources/PrivacyInfo.xcprivacy" "${RESOURCES_DIR}/PrivacyInfo.xcprivacy"
/usr/bin/install -m 644 "${ROOT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

# Sign with Developer ID Application, Hardened Runtime, secure timestamp.
/usr/bin/codesign --force --options runtime \
  --sign "${DEVELOPER_ID}" --timestamp \
  --entitlements "${ROOT_DIR}/Resources/ProjectEmber.entitlements" \
  "${APP_PATH}"

# Release gate on the app: Developer ID authority, TeamIdentifier, Hardened
# Runtime flag, codesign --verify, Location entitlement. Gatekeeper is not
# asserted here: a Developer ID app is only accepted once its notarization
# ticket exists, which is why the release expectations below run after stapling.
/bin/bash "${ROOT_DIR}/scripts/verify-release-artifacts.sh" --expect signed --app "${APP_PATH}"

# DMG, notarize, staple, verify.
/usr/bin/ditto "${APP_PATH}" "${STAGE_DIR}/dmg/Project Ember.app"
/bin/ln -sfn /Applications "${STAGE_DIR}/dmg/Applications"
# scripts/make-dmg.sh owns the hdiutil invocation and the reason there is no
# mount-free fallback (its header records the FinderInfo failure the gate
# caught).
/bin/bash "${ROOT_DIR}/scripts/make-dmg.sh" \
  --source "${STAGE_DIR}/dmg" \
  --volume-name "Project Ember ${VERSION}" \
  --output "${DMG_PATH}"

echo "Submitting ${DMG_PATH} for notarization (this can take minutes)…"
if xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait; then
  echo "Notarization accepted; fetching the log."
  # The submission already succeeded, so a missing log is not a release failure;
  # it must still be visible rather than silent.
  xcrun notarytool log --keychain-profile "${NOTARY_PROFILE}" "${DMG_PATH}" ||
    echo "warning: notarization succeeded but its log could not be fetched." >&2
else
  echo "error: notarization failed; fetching the notary log." >&2
  xcrun notarytool log --keychain-profile "${NOTARY_PROFILE}" "${DMG_PATH}" ||
    echo "error: the notary log could not be fetched either." >&2
  exit 1
fi

xcrun stapler staple "${DMG_PATH}"

# Release gate on the DMG: stapled ticket (stapler validate), Gatekeeper
# acceptance, mount + contents + version, and the app inside re-verified.
/bin/bash "${ROOT_DIR}/scripts/verify-release-artifacts.sh" --expect release --app "${APP_PATH}" --dmg "${DMG_PATH}"

shasum -a 256 "${DMG_PATH}" > "${CHECKSUM_PATH}"

echo "Release artifacts:"
echo "  ${DMG_PATH}"
echo "  ${CHECKSUM_PATH}"
