#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository=$(cd -- "${script_dir}/../.." && pwd)
build_type=${1:-Debug}
build_dir="${repository}/build/linux-${build_type,,}"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/project-ember-tests.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

cmake --build "${build_dir}" --parallel
export QT_QPA_PLATFORM=offscreen
export XDG_CONFIG_HOME="${test_root}/config"
export XDG_STATE_HOME="${test_root}/state"
export XDG_RUNTIME_DIR="${test_root}/runtime"
mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"
ctest --test-dir "${build_dir}" --output-on-failure
