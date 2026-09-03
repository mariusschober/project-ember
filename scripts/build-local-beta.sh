#!/bin/zsh
set -euo pipefail

# Local ad-hoc build for development (0.4.0). Production signing/notarization
# lives in scripts/build-production-release.sh.
ROOT_DIR="${0:A:h:h}"
WORKSPACE_DIR="${ROOT_DIR:h}"
VERSION="0.4.0"
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

if [[ -z "${SDK}" || ! -d "${SDK}" ]]; then
    print -u2 "Could not discover macOS SDK via xcrun."
    exit 1
fi
print "Using SDK: ${SDK}"

# Clean staging before use.
rm -rf "${DMG_STAGE}" "${APP_PATH}"
mkdir -p "${BUILD_DIR}" "${CACHE_DIR}/cache" "${CACHE_DIR}/config" "${CACHE_DIR}/security"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${OUTPUT_DIR}" "${DMG_STAGE}"

export SDKROOT="${SDK}"
export CLANG_MODULE_CACHE_PATH="${CACHE_DIR}/clang"
export SWIFT_MODULE_CACHE_PATH="${CACHE_DIR}/swift"

# Apple-Silicon product decision: arm64 only (documented in README/CHANGELOG).
swift build \
    --disable-sandbox \
    --jobs 1 \
    --configuration release \
    --cache-path "${CACHE_DIR}/cache" \
    --config-path "${CACHE_DIR}/config" \
    --security-path "${CACHE_DIR}/security" \
    --sdk "${SDK}" \
    --triple arm64-apple-macosx14.0 \
    --build-path "${BUILD_DIR}"

swift test --disable-sandbox --skip-build 2>/dev/null || swift test --disable-sandbox
"${BUILD_DIR}/arm64-apple-macosx/release/EmberCoreChecks"

/usr/bin/install -m 755 \
    "${BUILD_DIR}/arm64-apple-macosx/release/ProjectEmber" \
    "${MACOS_DIR}/ProjectEmber"
/usr/bin/install -m 644 "${ROOT_DIR}/Resources/Info.plist" "${CONTENTS}/Info.plist"
/usr/bin/install -m 644 \
    "${ROOT_DIR}/Resources/PrivacyInfo.xcprivacy" \
    "${RESOURCES_DIR}/PrivacyInfo.xcprivacy"
if [[ -f "${ROOT_DIR}/Resources/AppIcon.icns" ]]; then
    /usr/bin/install -m 644 "${ROOT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

/usr/bin/plutil -lint "${CONTENTS}/Info.plist" "${RESOURCES_DIR}/PrivacyInfo.xcprivacy"
/usr/bin/codesign \
    --force \
    --deep \
    --sign - \
    --timestamp=none \
    --entitlements "${ROOT_DIR}/Resources/ProjectEmber.entitlements" \
    "${APP_PATH}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

/usr/bin/ditto "${APP_PATH}" "${DMG_STAGE}/Project Ember.app"
/bin/ln -sfn /Applications "${DMG_STAGE}/Applications"
/usr/bin/hdiutil create \
    -volname "Project Ember Beta" \
    -srcfolder "${DMG_STAGE}" \
    -format UDZO \
    -ov \
    "${DMG_PATH}"

print "Built:"
print "  ${APP_PATH}"
print "  ${DMG_PATH}"
print ""
print "This beta is ad-hoc signed for local testing. Developer ID signing and"
print "notarization require an active Apple Developer Program membership."
print "See scripts/build-production-release.sh for the public release path."
