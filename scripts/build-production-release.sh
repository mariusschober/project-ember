#!/bin/zsh
set -euo pipefail

# Production Developer ID-signed + notarized release path for Project Ember 0.4.0.
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="ember-notary" \
#   scripts/build-production-release.sh
#
# Requirements: Apple Developer Program membership, Developer ID Application
# certificate in the login keychain, and a notarytool stored profile.
# This script never uses ad-hoc signing, --timestamp=none, or --deep as the
# public release procedure.
ROOT_DIR="${0:A:h:h}"
WORKSPACE_DIR="${ROOT_DIR:h}"
VERSION="0.4.0"
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your 'Developer ID Application: …' identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a stored notarytool profile}"

SDK="$(xcrun --show-sdk-path)"
BUILD_DIR="/private/tmp/ProjectEmberRelease-${UID}"
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
mkdir -p "${STAGE_DIR}/dmg" "${OUTPUT_DIR}"

print "SDK: ${SDK}"
print "Version: ${VERSION} (arm64 Apple Silicon; see README for product decision)"

export SDKROOT="${SDK}"
swift build \
    --disable-sandbox \
    --configuration release \
    --sdk "${SDK}" \
    --triple arm64-apple-macosx14.0 \
    --build-path "${BUILD_DIR}"
swift test --disable-sandbox
"${BUILD_DIR}/arm64-apple-macosx/release/EmberCoreChecks"
/usr/bin/plutil -lint "${ROOT_DIR}/Resources/Info.plist" "${ROOT_DIR}/Resources/PrivacyInfo.xcprivacy"

# Assemble bundle reproducibly.
CONTENTS="${APP_PATH}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
/usr/bin/install -m 755 "${BUILD_DIR}/arm64-apple-macosx/release/ProjectEmber" "${MACOS_DIR}/ProjectEmber"
/usr/bin/install -m 644 "${ROOT_DIR}/Resources/Info.plist" "${CONTENTS}/Info.plist"
/usr/bin/install -m 644 "${ROOT_DIR}/Resources/PrivacyInfo.xcprivacy" "${RESOURCES_DIR}/PrivacyInfo.xcprivacy"
/usr/bin/install -m 644 "${ROOT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

# Sign with Developer ID Application, Hardened Runtime, secure timestamp.
/usr/bin/codesign --force --options runtime \
    --sign "${DEVELOPER_ID}" --timestamp \
    --entitlements "${ROOT_DIR}/Resources/ProjectEmber.entitlements" \
    "${APP_PATH}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
/usr/bin/spctl --assess --type execute --verbose=2 "${APP_PATH}" || true

# DMG, notarize, staple, verify.
/usr/bin/ditto "${APP_PATH}" "${STAGE_DIR}/dmg/Project Ember.app"
/bin/ln -sfn /Applications "${STAGE_DIR}/dmg/Applications"
/usr/bin/hdiutil create -volname "Project Ember ${VERSION}" \
    -srcfolder "${STAGE_DIR}/dmg" -format UDZO -ov "${DMG_PATH}"
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun notarytool log --keychain-profile "${NOTARY_PROFILE}" "${DMG_PATH}" || true
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"
/usr/bin/spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}" || true

# Mount and smoke-check, then checksums.
MOUNT_DIR="/private/tmp/EmberDMGCheck-${UID}"
mkdir -p "${MOUNT_DIR}"
/usr/bin/hdiutil attach "${DMG_PATH}" -mountpoint "${MOUNT_DIR}" -nobrowse -readonly
ls "${MOUNT_DIR}"
/usr/bin/hdiutil detach "${MOUNT_DIR}" || true
rmdir "${MOUNT_DIR}" || true
shasum -a 256 "${DMG_PATH}" > "${CHECKSUM_PATH}"
cat "${CHECKSUM_PATH}"

print "Release artifacts:"
print "  ${DMG_PATH}"
print "  ${CHECKSUM_PATH}"
