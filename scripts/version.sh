#!/bin/bash
#
# Version truth for Project Ember.
#
# Sources/EmberCore/AppVersion.swift is the only file in which the product
# version is written down. This helper parses it so the build scripts, the
# assembled Info.plist, and CI all agree instead of each keeping a private copy
# (Stage 0.4). It is deliberately dependency-free and bash 3.2 compatible
# because it runs on macOS runners and on the author's Mac.
#
# Usage:
#   scripts/version.sh                   # shell assignments: MARKETING=… BUILD=…
#   scripts/version.sh --marketing       # 0.5.0
#   scripts/version.sh --build           # 5
#   scripts/version.sh --check [PATH…]   # exit non-zero unless every copy agrees
#
# --check validates:
#   1. AppVersion.swift parses and both numbers are well formed;
#   2. Resources/Info.plist carries the same CFBundleShortVersionString and
#      CFBundleVersion;
#   3. every extra PATH (a .app bundle or an Info.plist) matches as well;
#   4. no script or workflow pins a version literal of its own.
#
# Every failure exits non-zero: this script is used as a release gate, never as
# advice.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_VERSION_FILE="${ROOT_DIR}/Sources/EmberCore/AppVersion.swift"

fail() {
  echo "version.sh: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
scripts/version.sh [--marketing | --build | --check [PATH ...]]

  (no argument)   print shell assignments: MARKETING=… and BUILD=…
  --marketing     print the marketing version (for example 0.5.0)
  --build         print the build number (for example 5)
  --check [PATH]  fail unless AppVersion.swift, Resources/Info.plist and every
                  PATH (a .app bundle or an Info.plist) agree, and unless no
                  script or workflow pins a version literal of its own

The version lives only in Sources/EmberCore/AppVersion.swift.
USAGE
}

# read_swift_literal <property-name> — the value of a `public static let` string
# literal in AppVersion.swift. Fails closed on a missing file or missing key so
# a renamed property can never silently yield an empty version.
read_swift_literal() {
  local name="$1" value
  [[ -f "${APP_VERSION_FILE}" ]] || fail "missing ${APP_VERSION_FILE}"
  value="$(
    sed -n "s/^[[:space:]]*public static let ${name} = \"\([^\"]*\)\".*$/\1/p" \
      "${APP_VERSION_FILE}" | head -n 1
  )"
  [[ -n "${value}" ]] || fail "could not read '${name}' from ${APP_VERSION_FILE}"
  printf '%s' "${value}"
}

# plist_value <plist> <key>
plist_value() {
  local plist="$1" key="$2" value
  [[ -f "${plist}" ]] || fail "missing plist: ${plist}"
  if ! value="$(/usr/bin/plutil -extract "${key}" raw -o - "${plist}" 2>&1)"; then
    fail "could not read ${key} from ${plist}: ${value}"
  fi
  printf '%s' "${value}"
}

# resolve_plist <path> — accepts a bundle or the plist itself.
resolve_plist() {
  local path="$1"
  case "${path}" in
    *.app) printf '%s' "${path}/Contents/Info.plist" ;;
    *.plist) printf '%s' "${path}" ;;
    *) fail "expected a .app bundle or an Info.plist path, got: ${path}" ;;
  esac
}

# check_plist <label> <plist>
check_plist() {
  local label="$1" plist="$2" marketing build
  marketing="$(plist_value "${plist}" CFBundleShortVersionString)"
  build="$(plist_value "${plist}" CFBundleVersion)"
  [[ "${marketing}" == "${MARKETING}" ]] ||
    fail "${label}: CFBundleShortVersionString is '${marketing}', AppVersion.swift says '${MARKETING}'"
  [[ "${build}" == "${BUILD}" ]] ||
    fail "${label}: CFBundleVersion is '${build}', AppVersion.swift says '${BUILD}'"
  echo "version.sh: ok ${label} (${marketing} build ${build})"
}

# check_no_pinned_versions — scripts and workflows must derive the version, not
# pin it. Two shapes are rejected: the current marketing version written down
# anywhere (including a CI grep), and a `VERSION=…`/`MARKETING=…` assignment of
# any dotted version (a stale pin that would silently ship the wrong number).
# Historical prose about older releases is left alone.
check_no_pinned_versions() {
  local hits
  hits="$(
    grep -rnF --include='*.sh' --include='*.yml' --include='*.yaml' \
      --exclude='version.sh' -- "${MARKETING}" \
      "${ROOT_DIR}/scripts" "${ROOT_DIR}/.github/workflows" 2>/dev/null
  )" || hits=""
  if [[ -n "${hits}" ]]; then
    echo "version.sh: scripts and workflows must not pin the current version (${MARKETING}); found:" >&2
    printf '%s\n' "${hits}" >&2
    exit 1
  fi

  hits="$(
    grep -rnE --include='*.sh' --include='*.yml' --include='*.yaml' \
      --exclude='version.sh' \
      '^[[:space:]]*(VERSION|MARKETING|MARKETING_VERSION|BUILD_NUMBER)[[:space:]]*=[[:space:]]*"?[0-9]+\.[0-9]+' \
      "${ROOT_DIR}/scripts" "${ROOT_DIR}/.github/workflows" 2>/dev/null
  )" || hits=""
  if [[ -n "${hits}" ]]; then
    echo "version.sh: scripts and workflows must derive the version from AppVersion.swift; found a pinned assignment:" >&2
    printf '%s\n' "${hits}" >&2
    exit 1
  fi
}

MARKETING="$(read_swift_literal marketing)"
BUILD="$(read_swift_literal build)"

[[ "${MARKETING}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "malformed marketing version '${MARKETING}' in ${APP_VERSION_FILE}"
[[ "${BUILD}" =~ ^[0-9]+$ ]] ||
  fail "malformed build number '${BUILD}' in ${APP_VERSION_FILE}"

case "${1:-}" in
  "")
    printf 'MARKETING=%s\nBUILD=%s\n' "${MARKETING}" "${BUILD}"
    ;;
  --marketing)
    printf '%s\n' "${MARKETING}"
    ;;
  --build)
    printf '%s\n' "${BUILD}"
    ;;
  --check)
    shift
    check_plist "Resources/Info.plist" "${ROOT_DIR}/Resources/Info.plist"
    for path in "$@"; do
      check_plist "${path}" "$(resolve_plist "${path}")"
    done
    check_no_pinned_versions
    echo "version.sh: all copies agree (${MARKETING} build ${BUILD})"
    ;;
  -h | --help)
    usage
    ;;
  *)
    fail "unknown argument: $1"
    ;;
esac
