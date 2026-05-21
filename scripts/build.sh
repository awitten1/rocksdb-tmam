#!/usr/bin/env bash
# Configures (if needed) and builds the bench executable.
#
# Tunables:
#   BUILD_TYPE  CMake build type (default: RelWithDebInfo)
#   JOBS        parallel build jobs (default: nproc)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
JOBS="${JOBS:-$(nproc)}"
BUILD_DIR="$REPO_ROOT/build"

if [[ ! -d "$REPO_ROOT/local/rocksdb" ]]; then
  echo "[build] local RocksDB not found; run scripts/install_rocksdb.sh first" >&2
  exit 1
fi

if [[ ! -f "$BUILD_DIR/CMakeCache.txt" ]]; then
  echo "[build] configuring ($BUILD_TYPE)"
  cmake -S "$REPO_ROOT" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
fi

echo "[build] building with $JOBS jobs"
cmake --build "$BUILD_DIR" -j"$JOBS"

echo "[build] done -> $BUILD_DIR/bench"
