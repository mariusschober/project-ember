#!/bin/bash
#
# Local ad-hoc build of Project Ember for development and beta testing.
# Production Developer ID signing and notarization live in
# scripts/build-production-release.sh.
#
# This script writes only inside the workspace (outputs/, work/) and inside
# per-user scratch directories under /private/tmp. It never touches an installed
# copy of the app.
#
# Stages (each is a gate: a failure aborts before the next stage runs):
#   1. release build of the package (arm64, macOS 14) with an explicit SDK,
#      scratch path and cache
#   2. the unit-test suite in the *same* build tree and the *same* release
#      configuration as the binary that ships
#   3. EmberCoreChecks from that same build
#   4. bundle assembly, with the version stamped from AppVersion.swift
#   5. ad-hoc signature (location entitlement included) and the shared
#      artifact gate
#   6. DMG creation, then the shared gate again against the mounted image

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="$(cd "${ROOT_DIR}/.." && pwd)"

# Version truth is Sources/EmberCore/AppVersion.swift; never write it here.
VERSION="$(/bin/bash "${ROOT_DIR}/scripts/version.sh" --marketing)"
BUILD_NUMBER="$(/bin/bash "${ROOT_DIR}/scripts/version.sh" --build)"

SDK="$(xcrun --show-sdk-path 2>/dev/null || echo "")"
BUILD_DIR="/private/tmp/ProjectEmberBuild-${UID}"
CACHE_DIR="/private/tmp/ProjectEmberSwiftPM-${UID}"
OUTPUT_DIR="${WORKSPACE_DIR}/outputs"
APP_PATH="${OUTPUT_DIR}/Project Ember.app"
CONTENTS="${APP_PATH}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
DMG_STAGE="${WORKSPACE_DIR}/work/ProjectEmberDMG-${VERSION}"
DMG_PATH="${OUTPUT_DIR}/Project-Ember-${VERSION}-local-beta.dmg"
CHECKSUM_PATH="${OUTPUT_DIR}/Project-Ember-${VERSION}-local-beta.sha256"

if [[ -z "${SDK}" || ! -d "${SDK}" ]]; then
  echo "error: could not discover the macOS SDK via xcrun." >&2
  exit 1
fi
echo "Using SDK: ${SDK}"
echo "Version: ${VERSION} build ${BUILD_NUMBER} (arm64 Apple Silicon; see README)"

# Clean staging before use.
rm -rf "${DMG_STAGE}" "${APP_PATH}"
mkdir -p "${BUILD_DIR}" "${CACHE_DIR}/cache" "${CACHE_DIR}/config" "${CACHE_DIR}/security"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${OUTPUT_DIR}" "${DMG_STAGE}"

export SDKROOT="${SDK}"
export CLANG_MODULE_CACHE_PATH="${CACHE_DIR}/clang"
export SWIFT_MODULE_CACHE_PATH="${CACHE_DIR}/swift"

# Every SwiftPM invocation shares these flags, so the tests below compile into
# the same tree with the same SDK, triple and caches as the shipped binary.
#
# `--jobs 1` (0.4.0) is deliberately gone: it serialized every compilation and
# nothing in a package this small (EmberCore plus two small executables) needs
# it. Removing it restores SwiftPM's default parallelism.
SWIFT_FLAGS=(
  --disable-sandbox
  --cache-path "${CACHE_DIR}/cache"
  --config-path "${CACHE_DIR}/config"
  --security-path "${CACHE_DIR}/security"
  --sdk "${SDK}"
  --triple arm64-apple-macosx14.0
  --build-path "${BUILD_DIR}"
)

# Apple-Silicon product decision: arm64 only (documented in README/CHANGELOG).
swift build --configuration release "${SWIFT_FLAGS[@]}"

# Tests run in the same build tree, SDK and triple as the binary that ships, in
# both configurations. 0.4.0 ran `swift test --skip-build 2>/dev/null || swift
# test` against the package default .build tree, which tested a different build
# than the one in the DMG and discarded the first failure's stderr.
#
# Release is the configuration that ships. Debug is the only configuration in
# which the DEBUG-gated self-test modes and QA paths exist, so it is the only
# one that compiles them. (The production script runs the release suite only:
# debug-only code is not in the artifact it publishes, and CI covers the debug
# build on every change.)
swift test "${SWIFT_FLAGS[@]}"
swift test --configuration release "${SWIFT_FLAGS[@]}"

# Resolve the product directory from SwiftPM instead of assuming a layout: the
# 0.4.0 script hardcoded <build>/arm64-apple-macosx/release, which no longer
# matches the directory SwiftPM 6.4 produces.
RELEASE_DIR="$(swift build --configuration release "${SWIFT_FLAGS[@]}" --show-bin-path)"
[[ -x "${RELEASE_DIR}/ProjectEmber" ]] ||
  { echo "error: no release binary at ${RELEASE_DIR}/ProjectEmber" >&2; exit 1; }
[[ -x "${RELEASE_DIR}/EmberCoreChecks" ]] ||
  { echo "error: no EmberCoreChecks at ${RELEASE_DIR}/EmberCoreChecks" >&2; exit 1; }

"${RELEASE_DIR}/EmberCoreChecks"

/usr/bin/install -m 755 "${RELEASE_DIR}/ProjectEmber" "${MACOS_DIR}/ProjectEmber"
/usr/bin/install -m 644 "${ROOT_DIR}/Resources/Info.plist" "${CONTENTS}/Info.plist"
# Stamp the version from AppVersion.swift so the bundle can never disagree with
# the code it contains (Stage 0.4).
/usr/bin/plutil -replace CFBundleShortVersionString -string "${VERSION}" "${CONTENTS}/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "${BUILD_NUMBER}" "${CONTENTS}/Info.plist"
/usr/bin/install -m 644 \
  "${ROOT_DIR}/Resources/PrivacyInfo.xcprivacy" \
  "${RESOURCES_DIR}/PrivacyInfo.xcprivacy"
if [[ -f "${ROOT_DIR}/Resources/AppIcon.icns" ]]; then
  /usr/bin/install -m 644 "${ROOT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

/usr/bin/plutil -lint "${CONTENTS}/Info.plist" "${RESOURCES_DIR}/PrivacyInfo.xcprivacy"
/usr/bin/plutil -lint "${ROOT_DIR}/Resources/ProjectEmber.entitlements"

/usr/bin/codesign \
  --force \
  --deep \
  --sign - \
  --timestamp=none \
  --entitlements "${ROOT_DIR}/Resources/ProjectEmber.entitlements" \
  "${APP_PATH}"

# Shared gate: signature verifies, is ad-hoc, carries the Location entitlement,
# and the Info.plist agrees with AppVersion.swift.
/bin/bash "${ROOT_DIR}/scripts/verify-release-artifacts.sh" --expect adhoc --app "${APP_PATH}"

/usr/bin/ditto "${APP_PATH}" "${DMG_STAGE}/Project Ember.app"
/bin/ln -sfn /Applications "${DMG_STAGE}/Applications"
# scripts/make-dmg.sh owns the hdiutil invocation and the reason there is no
# mount-free fallback (its header records the FinderInfo failure the gate
# caught).
/bin/bash "${ROOT_DIR}/scripts/make-dmg.sh" \
  --source "${DMG_STAGE}" \
  --volume-name "Project Ember Beta" \
  --output "${DMG_PATH}"

# The mounted image is what a beta tester actually downloads.
/bin/bash "${ROOT_DIR}/scripts/verify-release-artifacts.sh" \
  --expect adhoc --app "${APP_PATH}" --dmg "${DMG_PATH}"

shasum -a 256 "${DMG_PATH}" > "${CHECKSUM_PATH}"

echo "Built:"
echo "  ${APP_PATH}"
echo "  ${DMG_PATH}"
echo "  ${CHECKSUM_PATH}"
echo ""
echo "This beta is ad-hoc signed for local testing. Developer ID signing and"
echo "notarization require an active Apple Developer Program membership;"
echo "see docs/RELEASE_RUNBOOK.md and scripts/build-production-release.sh."
