#!/usr/bin/env bash
# Builds RocksDB from source and installs it into ./local/rocksdb so the
# CMake project in this repo can find it via find_package(RocksDB CONFIG).
#
# Tunables (env vars):
#   ROCKSDB_VERSION  git tag/branch to check out (default: v9.7.3)
#   JOBS             parallel build jobs (default: nproc)
#   WITH_COMPRESSION 1 to enable snappy/lz4/zstd (requires system libs); 0 to skip (default: 0)
#
# The TMAM study benefits from frame pointers (cleaner perf callgraphs) and
# RelWithDebInfo (real optimizations + symbols), so both are forced on here.

set -euo pipefail

ROCKSDB_VERSION="${ROCKSDB_VERSION:-v11.1.1}"
JOBS="${JOBS:-$(nproc)}"
WITH_COMPRESSION="${WITH_COMPRESSION:-1}"

# Install compression dev libs via apt if they're missing.  Only attempt
# on systems where apt-get exists; skip silently otherwise.
if [[ "$WITH_COMPRESSION" == "1" ]] && command -v apt >/dev/null 2>&1; then
  missing=()
  for pkg in libsnappy-dev liblz4-dev libzstd-dev libgflags-dev; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    echo "[install_rocksdb] installing compression deps via apt: ${missing[*]}"
    sudo apt update
    sudo apt install -y "${missing[@]}"
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PREFIX="$REPO_ROOT/local/rocksdb"
SRC_DIR="$REPO_ROOT/local/src/rocksdb"
BUILD_DIR="$SRC_DIR/build"

mkdir -p "$PREFIX" "$(dirname "$SRC_DIR")"

need_clone=1
if [[ -d "$SRC_DIR/.git" ]]; then
  current="$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null || true)"
  if [[ "$current" == "$ROCKSDB_VERSION" ]]; then
    echo "[install_rocksdb] reusing existing checkout at $SRC_DIR ($current)"
    need_clone=0
  else
    echo "[install_rocksdb] existing checkout is at '${current:-unknown}', want $ROCKSDB_VERSION; re-cloning"
    rm -rf "$SRC_DIR" "$BUILD_DIR"
  fi
fi
if [[ $need_clone == 1 ]]; then
  echo "[install_rocksdb] cloning RocksDB $ROCKSDB_VERSION"
  git clone --depth 1 --branch "$ROCKSDB_VERSION" \
    https://github.com/facebook/rocksdb.git "$SRC_DIR"
fi

COMPRESSION_FLAGS=()
if [[ "$WITH_COMPRESSION" == "1" ]]; then
  COMPRESSION_FLAGS+=( -DWITH_SNAPPY=ON -DWITH_LZ4=ON -DWITH_ZSTD=ON )
else
  COMPRESSION_FLAGS+=( -DWITH_SNAPPY=OFF -DWITH_LZ4=OFF -DWITH_ZSTD=OFF -DWITH_BZ2=OFF -DWITH_ZLIB=OFF )
fi

echo "[install_rocksdb] configuring"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_CXX_FLAGS="-fno-omit-frame-pointer" \
  -DCMAKE_C_FLAGS="-fno-omit-frame-pointer" \
  -DROCKSDB_BUILD_SHARED=OFF \
  -DWITH_GFLAGS=ON \
  -DWITH_LIBURING=OFF \
  -DWITH_TESTS=OFF \
  -DWITH_BENCHMARK_TOOLS=OFF \
  -DWITH_TOOLS=ON \
  -DUSE_RTTI=1 \
  -DFAIL_ON_WARNINGS=OFF \
  -G Ninja \
  "${COMPRESSION_FLAGS[@]}"

echo "[install_rocksdb] building with $JOBS jobs"
cmake --build "$BUILD_DIR" -j"$JOBS"

echo "[install_rocksdb] installing into $PREFIX"
cmake --install "$BUILD_DIR"

# RocksDB's CMake install target doesn't install the admin tools; copy them
# in manually so `ldb`, `sst_dump`, etc. live alongside the library.
mkdir -p "$PREFIX/bin"
for tool in ldb sst_dump; do
  if [[ -x "$BUILD_DIR/tools/$tool" ]]; then
    install -m 0755 "$BUILD_DIR/tools/$tool" "$PREFIX/bin/$tool"
    echo "[install_rocksdb] installed $PREFIX/bin/$tool"
  fi
done

echo "[install_rocksdb] done. RocksDBConfig.cmake at:"
find "$PREFIX" -name 'RocksDBConfig.cmake' -print
