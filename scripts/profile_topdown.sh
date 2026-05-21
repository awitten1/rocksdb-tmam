#!/usr/bin/env bash
# Runs the bench executable under `perf stat` collecting the top-down
# microarchitectural breakdown for a single workload phase.
#
# Usage:
#   profile_topdown.sh <workload> [extra bench args...]
#
# Workloads: fillseq | fillrandom | overwrite | readrandom_hot | readrandom_cold | readseq
#
# Notes:
#   On AMD Zen, perf exposes topdown via the metric groups `PipelineL1`
#   (Retiring / Bad-Spec / Frontend-Bound / Backend-Bound) and `PipelineL2`
#   (sub-decomposition into latency vs bandwidth, memory vs core, etc).
#   On Intel, the same idea is reached via `perf stat --topdown`.
#
#   This requires kernel.perf_event_paranoid <= 2.  The script checks and
#   prints the fix command if it's higher.

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: profile_topdown.sh <workload> [bench args...]
       profile_topdown.sh -h | --help

Runs build/bench under `perf stat` and collects the top-down
microarchitectural breakdown for a single workload phase.

Workloads:
  fillseq          sequential writes; stresses memtable + WAL
  fillrandom      random writes; stresses skiplist locality
  overwrite        random writes over an existing DB; mixes with compaction
  readrandom_hot   random reads over a small key range; expect cache hits
  readrandom_cold  random reads over full key range; expect cache misses
  readseq          full forward iteration; stresses iterator merge + decompress

Read-style workloads expect the DB at ./db/<workload> to already exist.
If it doesn't, the script populates it with `fillrandom` first.

Extra args after the workload are forwarded to bench. Run
`build/bench --help` for the full list of bench flags.

Environment:
  CPULIST   physical CPUs to pin the run to (default: 2,3)

Output: results/<workload>-<timestamp>.txt

Requires kernel.perf_event_paranoid <= 2. The script checks and
prints the sysctl fix command if it's higher.

On AMD Zen the breakdown comes from `perf stat -M PipelineL2`;
on Intel from `perf stat --topdown --td-level=2`.
EOF
}

if [[ $# -lt 1 ]]; then
  print_usage >&2
  exit 2
fi

case "$1" in
  -h|--help) print_usage; exit 0 ;;
esac

WORKLOAD="$1"; shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BENCH="$REPO_ROOT/build/bench"
DB_DIR="$REPO_ROOT/db/$WORKLOAD"
RESULTS_DIR="$REPO_ROOT/results"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$RESULTS_DIR/${WORKLOAD}-${STAMP}.txt"

mkdir -p "$RESULTS_DIR"

if [[ ! -x "$BENCH" ]]; then
  echo "bench not built; run: cmake -S . -B build && cmake --build build -j" >&2
  exit 1
fi

# perf_event_paranoid >= 3 blocks PMU access for unprivileged users.
PARANOID="$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 4)"
if (( PARANOID > 2 )); then
  cat >&2 <<EOF
perf_event_paranoid is $PARANOID, which blocks PMU events for non-root users.
Lower it (for this boot) with:
  sudo sysctl -w kernel.perf_event_paranoid=2
Or persist it via /etc/sysctl.d/.
EOF
  exit 1
fi

# Phases that read need data on disk.  For read* workloads we expect the
# caller to have run fillrandom first into the same db dir; we don't wipe.
case "$WORKLOAD" in
  fillseq|fillrandom)
    rm -rf "$DB_DIR"
    ;;
  readrandom_hot|readrandom_cold|readseq|overwrite)
    if [[ ! -d "$DB_DIR" ]]; then
      echo "warning: $DB_DIR does not exist; populating with fillrandom first" >&2
      "$BENCH" --workload fillrandom --db "$DB_DIR" "$@"
      # drop OS page cache so cold reads are truly cold
      sync
      if [[ -w /proc/sys/vm/drop_caches ]]; then echo 3 > /proc/sys/vm/drop_caches || true; fi
    fi
    ;;
esac

# Pin to two physical cores on socket 0 to reduce scheduler/SMT noise.
# Adjust CPULIST if you want to look at SMT effects specifically.
CPULIST="${CPULIST:-2,3}"

# Detect CPU vendor to pick the right topdown events.
VENDOR="$(awk -F: '/vendor_id/ {print $2; exit}' /proc/cpuinfo | tr -d ' ')"

# Auxiliary counters that drill into the L1 breakdown.  Keep this list short
# enough to fit in one multiplexing group so the numbers stay precise.
AUX_EVENTS=(
  task-clock cycles instructions
  branches branch-misses
  cache-references cache-misses
  L1-dcache-loads L1-dcache-load-misses
  dTLB-loads dTLB-load-misses
)

run_perf() {
  local -a topdown_args
  if [[ "$VENDOR" == "GenuineIntel" ]]; then
    topdown_args=( --topdown --td-level=2 )
  else
    # AMD Zen exposes topdown via metric groups, not raw events.
    # PipelineL2 gives the level-1 split *and* its sub-decomposition.
    topdown_args=( -M PipelineL2 )
  fi

  local aux_csv
  aux_csv="$(IFS=,; echo "${AUX_EVENTS[*]}")"

  echo "# host:     $(hostname)"
  echo "# date:     $(date -Iseconds)"
  echo "# cpu:      $(lscpu | awk -F: '/Model name/ {print $2; exit}' | sed 's/^ *//')"
  echo "# vendor:   $VENDOR"
  echo "# cpulist:  $CPULIST"
  echo "# workload: $WORKLOAD"
  echo "# bench:    $BENCH --workload $WORKLOAD --db $DB_DIR $*"
  echo

  set -x
  taskset -c "$CPULIST" \
    perf stat "${topdown_args[@]}" -e "$aux_csv" -- \
    "$BENCH" --workload "$WORKLOAD" --db "$DB_DIR" "$@"
  { set +x; } 2>/dev/null
}

# perf writes its summary to stderr; capture both streams.
run_perf "$@" 2>&1 | tee "$OUT"

echo
echo "results -> $OUT"
