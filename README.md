# rocksdb-tmam

A small harness for studying RocksDB with the **Top-down Microarchitectural Analysis Method** (TMAM).

The idea: drive RocksDB through phases that stress different layers (memtable, block cache, SST, decompression, iterator merge), profile each phase in isolation with `perf stat`'s topdown breakdown, and compare where pipeline slots go.

## Layout

```
scripts/install_rocksdb.sh    # builds RocksDB into ./local/rocksdb
CMakeLists.txt                # finds RocksDB there, builds ./build/bench
src/bench.cpp                 # one tight loop per workload phase
scripts/profile_topdown.sh    # runs bench under perf stat --topdown
```

## Quick start

```bash
# 1. Build RocksDB locally (one time, ~5-10 min)
./scripts/install_rocksdb.sh

# 2. Build the bench executable
cmake -S . -B build
cmake --build build -j

# 3. Profile a phase.  fillrandom first so the read phases have data.
./scripts/profile_topdown.sh fillrandom     --keys 2000000 --value-size 256
./scripts/profile_topdown.sh readrandom_cold --keys 2000000 --ops 500000
./scripts/profile_topdown.sh readrandom_hot  --keys 2000000 --ops 500000 --cache-mb 512
./scripts/profile_topdown.sh readseq         --keys 2000000

# Results land in ./results/<workload>-<timestamp>.txt
```

## Workload phases and predicted TMAM signatures

| Phase             | Stresses                              | Predicted bottleneck       |
|-------------------|---------------------------------------|----------------------------|
| `fillseq`         | memtable insert, WAL append           | Backend / Memory           |
| `fillrandom`      | skiplist with poor locality           | Backend / Memory (DRAM)    |
| `readrandom_hot`  | block cache hits, hash lookup         | Retiring or Backend / Core |
| `readrandom_cold` | block cache miss, SST index lookup    | Backend / Memory + Core    |
| `readseq`         | iterator merge, decompression         | Backend / Core             |
| `overwrite`       | foreground writes + bg compaction     | Mixed                      |

Each result file includes the level-1 breakdown plus IPC, branch mispredict
rate, LLC miss rate, and dTLB miss rate so you can drill into whichever
bucket dominates.

## Knobs worth flipping between runs

- `--cache-mb` — forces hot vs. cold read paths.
- `--no-compression` — isolates decompression cost in `readseq` and `readrandom_cold`.
- `--value-size` — larger values shift pressure from skiplist to memcpy/decompress.
- `--threads` — for `readrandom_*`, SMT contention shows up as Backend / Core.

## Notes

- The host here is AMD Zen 5; the profile script uses AMD's level-1 topdown
  events. On Intel, it falls back to `perf stat --topdown --td-level=2`
  which gives sub-bucket detail (e.g., Memory-Bound → L3-Bound).
- For tighter numbers: `cpupower frequency-set -g performance`, disable
  turbo, and pin the bench to physical cores via `CPULIST=...`.
- `perf` needs either `CAP_PERFMON` or `kernel.perf_event_paranoid <= 1`.
