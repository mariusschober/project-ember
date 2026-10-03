#!/bin/bash
#
# Hard release gate for a Project Ember app bundle and, optionally, its DMG.
#
# Shared by scripts/build-local-beta.sh (--expect adhoc),
# scripts/build-production-release.sh (--expect signed before notarization and
# --expect release after stapling) and .github/workflows/release.yml, so the
# assertions a public release depends on cannot live only inside a script that
# CI never runs.
#
# Usage:
#   scripts/verify-release-artifacts.sh --app <bundle> [--dmg <dmg>]
#                                       [--expect adhoc|signed|release]
#
# Expectations:
#   adhoc    Local development build: the signature must be ad-hoc and verify,
#            the location entitlement must be present, and — when --dmg is
#            given — the mounted image must contain a verifiable app plus the
#            /Applications symlink at the stamped version. Gatekeeper rejection
#            is the expected outcome for an ad-hoc bundle, which is exactly why
#            the release expectations must never be used here.
#   signed   Post-signing, pre-notarization: everything in adhoc except that the
#            authority must be "Developer ID Application" with a TeamIdentifier
#            and the Hardened Runtime flag. No Gatekeeper assertion, because a
#            Developer ID app is only accepted once its notarization ticket
#            exists.
#   release  Everything in signed, plus a DMG (required) whose notarization
#            ticket is stapled, which Gatekeeper accepts, whose mounted copy is
#            a verifiable Developer ID app that Gatekeeper accepts for
#            execution and that matches the stamped version.
#
# Both signed modes also require the Location entitlement, because the Sun
# schedule is denied by the Hardened Runtime without it.
#
# Every failure exits non-zero and prints "verify-release-artifacts: FAIL: …".
# This is a gate: it never downgrades a failure to a warning.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXPECT="release"
APP=""
DMG=""
MOUNT_DIR=""

fail() {
  echo "verify-release-artifacts: FAIL: $*" >&2
  exit 1
}

note() {
  echo "verify-release-artifacts: $*"
}

# plist_raw <plist> <key> — a plist value, or a loud failure. Never let `set -e`
# turn a missing key into a silent exit: a gate has to say what went wrong.
plist_raw() {
  local plist="$1" key="$2" value
  if ! value="$(/usr/bin/plutil -extract "${key}" raw -o - "${plist}" 2>&1)"; then
    fail "could not read ${key} from ${plist}: ${value}"
  fi
  printf '%s' "${value}"
}

usage() {
  cat <<'USAGE'
scripts/verify-release-artifacts.sh --app <bundle> [--dmg <dmg>]
                                    [--expect adhoc|signed|release]

  --app     path to the assembled "Project Ember.app"
  --dmg     path to the disk image to mount and inspect
  --expect  adhoc, signed, or release (default: release)

Exits non-zero on the first assertion that fails.
USAGE
}

# Gatekeeper is asked with spctl where it exists. Note that spctl lives in
# /usr/sbin on macOS, not /usr/bin — calling /usr/bin/spctl unconditionally (as
# the 0.4.0 script did) fails with "No such file or directory", which is one of
# the failures that script's trailing `true` swallowed. On macOS 15.4+ spctl is
# deprecated in favour of syspolicy_check distribution, which runs the same
# Gatekeeper checks; use it when spctl is gone and fail closed when neither
# exists.
SPCTL=""
if command -v spctl >/dev/null 2>&1; then
  SPCTL="$(command -v spctl)"
elif [[ -x /usr/sbin/spctl ]]; then
  SPCTL="/usr/sbin/spctl"
fi
SYSPOLICY=""
if [[ -x /usr/bin/syspolicy_check ]]; then
  SYSPOLICY="/usr/bin/syspolicy_check"
fi

# Best-effort cleanup, not a gate: a leaked mount is annoying, a false failure
# on a release is worse. The explicit detach in the success path is a gate.
detach_mount() {
  [[ -n "${MOUNT_DIR}" ]] || return 0
  if /usr/bin/hdiutil detach "${MOUNT_DIR}" -quiet; then
    /bin/rmdir "${MOUNT_DIR}" || note "could not remove mount point ${MOUNT_DIR}"
  else
    note "warning: could not detach ${MOUNT_DIR}; detach it by hand before retrying"
  fi
  MOUNT_DIR=""
  return 0
}

# assert_gatekeeper_app <app> — the app must be accepted for execution. Only
# meaningful once the notarization ticket exists, so callers pass the copy
# inside the stapled disk image.
assert_gatekeeper_app() {
  local app="$1"
  if [[ -n "${SPCTL}" ]]; then
    note "Gatekeeper assessment: ${SPCTL} --assess --type execute ${app}"
    "${SPCTL}" --assess --type execute --verbose=2 "${app}" ||
      fail "Gatekeeper rejected ${app} (${SPCTL} --assess --type execute)"
  elif [[ -n "${SYSPOLICY}" ]]; then
    note "Gatekeeper assessment: ${SYSPOLICY} distribution ${app} (spctl is not installed)"
    "${SYSPOLICY}" distribution "${app}" ||
      fail "Gatekeeper rejected ${app} (syspolicy_check distribution)"
  else
    fail "no Gatekeeper assessment tool available (spctl and syspolicy_check are both missing)"
  fi
}

# check_dmg <notarized|local>
check_dmg() {
  local mode="$1"
  [[ -f "${DMG}" ]] || fail "DMG not found: ${DMG}"

  if [[ "${mode}" == "notarized" ]]; then
    note "stapler validate ${DMG}"
    xcrun stapler validate "${DMG}" ||
      fail "stapler validate failed: no notarization ticket is stapled to ${DMG}"
    [[ -n "${SPCTL}" ]] || fail "spctl is required to assess the disk image"
    note "Gatekeeper assessment: ${SPCTL} --assess --type open ${DMG}"
    "${SPCTL}" --assess --type open --context context:primary-signature --verbose=2 "${DMG}" ||
      fail "Gatekeeper rejected the disk image (${SPCTL} --assess --type open)"
  fi

  MOUNT_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ember-verify.XXXXXX")" ||
    fail "could not create a mount point"
  trap detach_mount EXIT
  /usr/bin/hdiutil attach "${DMG}" -mountpoint "${MOUNT_DIR}" -nobrowse -readonly -quiet ||
    fail "could not mount ${DMG}"

  MOUNTED_APP="${MOUNT_DIR}/Project Ember.app"
  [[ -d "${MOUNTED_APP}" ]] || fail "the DMG does not contain 'Project Ember.app'"
  [[ -x "${MOUNTED_APP}/Contents/MacOS/ProjectEmber" ]] ||
    fail "the app inside the DMG has no executable"
  [[ -L "${MOUNT_DIR}/Applications" ]] ||
    fail "the DMG has no /Applications symlink (drag-to-install would not work)"
  LINK_TARGET="$(/usr/bin/readlink "${MOUNT_DIR}/Applications")"
  [[ "${LINK_TARGET}" == "/Applications" ]] ||
    fail "the Applications symlink points at '${LINK_TARGET}', expected '/Applications'"

  /usr/bin/codesign --verify --deep --strict --verbose=2 "${MOUNTED_APP}" ||
    fail "the app inside the DMG does not verify"

  if [[ "${EXPECT}" != "adhoc" ]]; then
    MOUNTED_AUTHORITY="$(
      /usr/bin/codesign -d --verbose=4 "${MOUNTED_APP}" 2>&1 |
        grep '^Authority=Developer ID Application' | head -n 1
    )" || MOUNTED_AUTHORITY=""
    [[ -n "${MOUNTED_AUTHORITY}" ]] ||
      fail "the app inside the DMG is not signed with a Developer ID Application certificate"
  fi

  MOUNTED_VERSION="$(plist_raw "${MOUNTED_APP}/Contents/Info.plist" CFBundleShortVersionString)"
  MOUNTED_BUILD="$(plist_raw "${MOUNTED_APP}/Contents/Info.plist" CFBundleVersion)"
  APP_VERSION_VALUE="$(plist_raw "${APP}/Contents/Info.plist" CFBundleShortVersionString)"
  APP_BUILD_VALUE="$(plist_raw "${APP}/Contents/Info.plist" CFBundleVersion)"
  [[ "${MOUNTED_VERSION}" == "${APP_VERSION_VALUE}" && "${MOUNTED_BUILD}" == "${APP_BUILD_VALUE}" ]] ||
    fail "the DMG ships ${MOUNTED_VERSION} build ${MOUNTED_BUILD} but the verified app is ${APP_VERSION_VALUE} build ${APP_BUILD_VALUE}"

  if [[ "${mode}" == "notarized" ]]; then
    assert_gatekeeper_app "${MOUNTED_APP}"
  fi

  note "DMG contents verified: app + /Applications symlink, ${MOUNTED_VERSION} build ${MOUNTED_BUILD}"
  detach_mount
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app | --dmg | --expect)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      case "$1" in
        --app) APP="$2" ;;
        --dmg) DMG="$2" ;;
        --expect) EXPECT="$2" ;;
      esac
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

case "${EXPECT}" in
  adhoc | signed | release) ;;
  *) fail "--expect must be 'adhoc', 'signed' or 'release' (got '${EXPECT}')" ;;
esac

[[ -n "${APP}" ]] || fail "missing --app <bundle>"
APP="${APP%/}"
[[ -d "${APP}" ]] || fail "app bundle not found: ${APP}"
[[ -x "${APP}/Contents/MacOS/ProjectEmber" ]] ||
  fail "app binary missing or not executable: ${APP}/Contents/MacOS/ProjectEmber"

if [[ "${EXPECT}" == "release" && -z "${DMG}" ]]; then
  fail "--expect release needs --dmg: Gatekeeper acceptance cannot be asserted on an app whose notarization ticket does not exist yet (use --expect signed before notarizing)"
fi

"${SCRIPT_DIR}/version.sh" --check "${APP}" || fail "version agreement check failed for ${APP}"

note "signature integrity: codesign --verify --deep --strict ${APP}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP}" ||
  fail "codesign --verify --deep --strict rejected ${APP}"

SIGN_INFO="$(/usr/bin/codesign -d --verbose=4 "${APP}" 2>&1)" ||
  fail "could not read the signature of ${APP}"

if [[ "${EXPECT}" == "adhoc" ]]; then
  printf '%s\n' "${SIGN_INFO}" | grep -q '^Signature=adhoc' ||
    fail "--expect adhoc, but ${APP} is not ad-hoc signed"
  if printf '%s\n' "${SIGN_INFO}" | grep -q '^Authority=Developer ID Application'; then
    fail "--expect adhoc, but ${APP} carries a Developer ID Application signature"
  fi
  note "adhoc signature verified (Gatekeeper rejection is expected in this mode)"
else
  # `set -e` plus `pipefail` means the || guards below are required: a no-match
  # grep would otherwise abort the script before it can print the assertion.
  AUTHORITY="$(printf '%s\n' "${SIGN_INFO}" | grep '^Authority=' | head -n 1)" || AUTHORITY=""
  TEAM_ID="$(printf '%s\n' "${SIGN_INFO}" | sed -n 's/^TeamIdentifier=//p' | head -n 1)" || TEAM_ID=""
  FLAGS="$(printf '%s\n' "${SIGN_INFO}" | sed -n 's/^flags=//p' | head -n 1)" || FLAGS=""
  note "  authority=${AUTHORITY:-<none>}"
  note "  team=${TEAM_ID:-<none>}"
  note "  flags=${FLAGS:-<none>}"

  [[ "${AUTHORITY}" == "Authority=Developer ID Application"* ]] ||
    fail "expected a 'Developer ID Application' authority, found '${AUTHORITY:-none}'. A Developer ID certificate must be in the keychain and DEVELOPER_ID must name it."
  [[ -n "${TEAM_ID}" && "${TEAM_ID}" != "not set" ]] ||
    fail "the signature has no TeamIdentifier (not a Developer ID signature)"
  case "${FLAGS}" in
    *runtime*) ;;
    *) fail "the Hardened Runtime flag is missing (flags=${FLAGS:-none}); sign with --options runtime" ;;
  esac
fi

ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements :- "${APP}" 2>/dev/null)" ||
  fail "could not read the entitlements of ${APP}"
printf '%s' "${ENTITLEMENTS}" |
  grep -q 'com.apple.security.personal-information.location' ||
  fail "the Location entitlement is missing: the Sun schedule would be denied under the Hardened Runtime"
note "entitlement present: com.apple.security.personal-information.location"

if [[ -n "${DMG}" ]]; then
  if [[ "${EXPECT}" == "release" ]]; then
    check_dmg notarized
  else
    check_dmg local
  fi
fi

note "PASS: ${APP}${DMG:+ and ${DMG}} satisfy the '${EXPECT}' expectations"
