#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository=$(cd -- "${script_dir}/../.." && pwd)
build_type=${1:-Debug}
build_dir="${repository}/build/linux-${build_type,,}"

cmake -S "${repository}/linux" -B "${build_dir}" -G Ninja \
  -DCMAKE_BUILD_TYPE="${build_type}" \
  -DBUILD_TESTING=ON
cmake --build "${build_dir}" --parallel
