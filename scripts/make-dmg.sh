#!/bin/bash
#
# Build the Project Ember disk image (called by both build scripts).
#
# Usage:
#   scripts/make-dmg.sh --source <folder> --volume-name <name> --output <dmg>
#
# The only supported construction is Apple's canonical
#   hdiutil create -volname <name> -srcfolder <folder> -format UDZO -ov <dmg>
# which produces a compressed, read-only UDIF image containing an HFS+ volume.
#
# There is deliberately no fallback. `hdiutil makehybrid -hfs` can build an HFS+
# filesystem without mounting a temporary image, but it stamps every file with a
# com.apple.FinderInfo attribute; the app inside such an image then fails
# `codesign --verify --deep --strict` with "resource fork, Finder information,
# or similar detritus not allowed", which is exactly what the release gate
# rejects. A non-distributable image is worse than a loud failure, so this
# script fails instead of falling back.
#
# macOS 27 deprecates `hdiutil create` ("Please use 'diskutil image create
# from/blank'"), and the command needs to mount a temporary read/write image,
# which restricted environments refuse. If it fails here, run the release from a
# normal login session: nothing about that failure is specific to the artifacts
# being packaged.
#
# Exits non-zero if the image is not produced.

set -euo pipefail

SOURCE=""
VOLUME_NAME=""
OUTPUT=""

fail() {
  echo "make-dmg: FAIL: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
scripts/make-dmg.sh --source <folder> --volume-name <name> --output <dmg>

  --source       folder whose contents become the image
  --volume-name  name the mounted volume shows in Finder
  --output       path of the .dmg to create (overwritten)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source | --volume-name | --output)
      [[ $# -ge 2 ]] || fail "$1 requires a value"
      case "$1" in
        --source) SOURCE="$2" ;;
        --volume-name) VOLUME_NAME="$2" ;;
        --output) OUTPUT="$2" ;;
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

[[ -n "${SOURCE}" ]] || fail "missing --source <folder>"
[[ -d "${SOURCE}" ]] || fail "source folder not found: ${SOURCE}"
[[ -n "${VOLUME_NAME}" ]] || fail "missing --volume-name <name>"
[[ -n "${OUTPUT}" ]] || fail "missing --output <dmg>"
OUTPUT_DIR="$(/usr/bin/dirname "${OUTPUT}")"
[[ -d "${OUTPUT_DIR}" ]] || fail "output directory does not exist: ${OUTPUT_DIR}"

rm -f "${OUTPUT}"

echo "make-dmg: ${OUTPUT} (volume '${VOLUME_NAME}', source ${SOURCE})"
if ! /usr/bin/hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${SOURCE}" \
  -format UDZO \
  -ov "${OUTPUT}"; then
  fail "hdiutil create did not produce ${OUTPUT}. hdiutil needs to mount a temporary read/write image, and restricted environments (sandboxes, sessions without a login context) refuse that. Run the build from a normal terminal session."
fi

[[ -f "${OUTPUT}" ]] || fail "hdiutil reported success but no image exists at ${OUTPUT}"
echo "make-dmg: created ${OUTPUT}"
