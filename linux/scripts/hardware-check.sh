#!/usr/bin/env bash
set -euo pipefail

if [[ "${EMBER_HARDWARE_ACCEPT:-}" != "1" ]]; then
  echo "Refusing hardware acceptance checks without EMBER_HARDWARE_ACCEPT=1." >&2
  echo "These checks are read-only probes; ordinary builds and tests never need this flag." >&2
  exit 2
fi

if [[ -z "${WAYLAND_DISPLAY:-}" || -z "${XDG_RUNTIME_DIR:-}" ]]; then
  echo "A live Wayland session with XDG_RUNTIME_DIR is required." >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository=$(cd -- "${script_dir}/../.." && pwd)
binary=${PROJECT_EMBER_BINARY:-"${repository}/build/linux-release/project-ember"}

echo "Read-only Project Ember platform probe:"
"${binary}" --system-probe --json
echo
echo "No automatic display mutation is performed by this script. Follow linux/docs/HARDWARE_ACCEPTANCE.md for the explicit manual rows."
