// Small, phase-explicit RocksDB driver for top-down microarchitectural analysis.
//
// Each workload is a single tight loop so the TMAM signature attributable
// to that phase isn't muddled by setup/teardown.  Run one phase per perf
// invocation; the wrapper script handles that.
//
// Usage:
//   bench --workload <name> --db <path> [--keys N] [--value-size B]
//         [--ops N] [--threads T] [--cache-mb M] [--no-compression]
//
// Workloads:
//   fillseq         sequential keys, single writer
//   fillrandom      random keys, single writer
//   overwrite       random keys over a pre-populated DB (mixes with compaction)
//   readrandom_hot  random reads, small key space sized to fit in block cache
//   readrandom_cold random reads over the full DB with a tiny block cache
//   readseq         full forward iteration

#include <rocksdb/db.h>
#include <rocksdb/options.h>
#include <rocksdb/table.h>
#include <rocksdb/cache.h>
#include <rocksdb/filter_policy.h>
#include <rocksdb/iterator.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <thread>
#include <vector>

namespace {

struct Config {
  std::string workload;
  std::string db_path = "./db";
  uint64_t    keys = 1'000'000;
  uint64_t    ops = 0;            // 0 = derive from workload
  size_t      value_size = 100;
  int         threads = 1;
  size_t      cache_mb = 64;
  bool        compression = true; // ignored if RocksDB built without compression
};

[[noreturn]] void die(const std::string& msg) {
  std::fprintf(stderr, "bench: %s\n", msg.c_str());
  std::exit(1);
}

void print_usage(std::FILE* out) {
  std::fprintf(out,
    "Usage: bench --workload <name> [options]\n"
    "\n"
    "RocksDB workload driver for top-down microarchitectural analysis.\n"
    "Run one phase per invocation; profile externally with perf stat.\n"
    "\n"
    "Required:\n"
    "  --workload <name>      one of: fillseq, fillrandom, overwrite,\n"
    "                         readrandom_hot, readrandom_cold, readseq\n"
    "\n"
    "Options:\n"
    "  --db <path>            DB directory (default: ./db)\n"
    "  --keys <N>             size of the key range; keys are drawn from 0..N-1\n"
    "                         (default: 1000000). Upper-bounds on-disk size at\n"
    "                         roughly N * value-size.\n"
    "  --ops <N>              operations to perform (default: --keys)\n"
    "  --value-size <bytes>   value size in bytes (default: 100)\n"
    "  --threads <T>          reader threads for readrandom_* (default: 1)\n"
    "  --cache-mb <M>         block cache size in MiB (default: 64)\n"
    "  --no-compression       disable Snappy compression on SSTs\n"
    "  -h, --help             show this help and exit\n"
    "\n"
    "Workload notes:\n"
    "  fillseq          sequential writes; stresses memtable + WAL\n"
    "  fillrandom       random writes; stresses skiplist locality\n"
    "  overwrite        random writes over an existing DB; mixes with compaction\n"
    "  readrandom_hot   random reads over a small key range; expect block cache hits\n"
    "  readrandom_cold  random reads over full key range; expect cache misses\n"
    "  readseq          full forward iteration; stresses iterator merge + decompress\n");
}

Config parse_args(int argc, char** argv) {
  Config c;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "-h" || a == "--help") {
      print_usage(stdout);
      std::exit(0);
    }
    auto need = [&](const char* what) -> std::string {
      if (i + 1 >= argc) die(std::string("missing value for ") + what);
      return argv[++i];
    };
    if      (a == "--workload")        c.workload = need("--workload");
    else if (a == "--db")              c.db_path = need("--db");
    else if (a == "--keys")            c.keys = std::stoull(need("--keys"));
    else if (a == "--ops")             c.ops = std::stoull(need("--ops"));
    else if (a == "--value-size")      c.value_size = std::stoul(need("--value-size"));
    else if (a == "--threads")         c.threads = std::stoi(need("--threads"));
    else if (a == "--cache-mb")        c.cache_mb = std::stoul(need("--cache-mb"));
    else if (a == "--no-compression")  c.compression = false;
    else {
      print_usage(stderr);
      die("unknown arg: " + a);
    }
  }
  if (c.workload.empty()) {
    print_usage(stderr);
    die("--workload is required");
  }
  return c;
}

// 16-byte fixed-width key.  Fixed width matters: variable-length encoding
// of integers would add a confound to the TMAM measurement.
std::string make_key(uint64_t i) {
  char buf[17];
  std::snprintf(buf, sizeof(buf), "%016lx", static_cast<unsigned long>(i));
  return std::string(buf, 16);
}

std::string make_value(size_t size, uint64_t seed) {
  std::string v(size, '\0');
  // Deterministic, incompressible-ish payload.
  uint64_t s = seed * 6364136223846793005ULL + 1442695040888963407ULL;
  for (size_t i = 0; i < size; ++i) {
    s = s * 6364136223846793005ULL + 1442695040888963407ULL;
    v[i] = static_cast<char>(s >> 56);
  }
  return v;
}

rocksdb::Options build_options(const Config& c) {
  rocksdb::Options opts;
  opts.create_if_missing = true;
  opts.compression = c.compression ? rocksdb::kSnappyCompression
                                   : rocksdb::kNoCompression;
  // Modest, deterministic background concurrency so compaction noise
  // doesn't dominate the foreground TMAM measurement.
  opts.IncreaseParallelism(4);
  opts.max_background_jobs = 4;
  opts.write_buffer_size = 64 << 20;

  rocksdb::BlockBasedTableOptions tbl;
  tbl.block_cache = rocksdb::NewLRUCache(c.cache_mb << 20);
  tbl.filter_policy.reset(rocksdb::NewBloomFilterPolicy(10, false));
  tbl.cache_index_and_filter_blocks = true;
  opts.table_factory.reset(rocksdb::NewBlockBasedTableFactory(tbl));

  return opts;
}

void check(const rocksdb::Status& s, const char* what) {
  if (!s.ok()) die(std::string(what) + ": " + s.ToString());
}

// ------------------------------- workloads -------------------------------

void run_fill(rocksdb::DB& db, const Config& c, bool random) {
  uint64_t ops = c.ops ? c.ops : c.keys;
  std::mt19937_64 rng(0xC0FFEE);
  rocksdb::WriteOptions wo;
  for (uint64_t i = 0; i < ops; ++i) {
    uint64_t k = random ? rng() % c.keys : i % c.keys;
    auto key = make_key(k);
    auto val = make_value(c.value_size, k);
    check(db.Put(wo, key, val), "Put");
  }
}

void run_readrandom(rocksdb::DB& db, const Config& c, uint64_t key_space) {
  uint64_t ops = c.ops ? c.ops : c.keys;
  auto worker = [&](int tid) {
    std::mt19937_64 rng(0xDEADBEEF ^ tid);
    rocksdb::ReadOptions ro;
    std::string value;
    uint64_t per_thread = ops / c.threads;
    for (uint64_t i = 0; i < per_thread; ++i) {
      uint64_t k = rng() % key_space;
      auto key = make_key(k);
      auto s = db.Get(ro, key, &value);
      if (!s.ok() && !s.IsNotFound()) die("Get: " + s.ToString());
    }
  };
  std::vector<std::thread> ts;
  for (int t = 0; t < c.threads; ++t) ts.emplace_back(worker, t);
  for (auto& t : ts) t.join();
}

void run_readseq(rocksdb::DB& db, const Config& c) {
  uint64_t target = c.ops ? c.ops : c.keys;
  rocksdb::ReadOptions ro;
  std::unique_ptr<rocksdb::Iterator> it(db.NewIterator(ro));
  uint64_t seen = 0;
  for (it->SeekToFirst(); it->Valid() && seen < target; it->Next()) {
    // Touch the value so the decompress / copy path actually runs.
    volatile char sink = it->value().data()[0];
    (void)sink;
    ++seen;
  }
  check(it->status(), "iterator");
}

}  // namespace

int main(int argc, char** argv) {
  Config c = parse_args(argc, argv);

  rocksdb::Options opts = build_options(c);
  std::unique_ptr<rocksdb::DB> db;
  check(rocksdb::DB::Open(opts, c.db_path, &db), "Open");

  auto t0 = std::chrono::steady_clock::now();

  if      (c.workload == "fillseq")         run_fill(*db, c, /*random=*/false);
  else if (c.workload == "fillrandom")      run_fill(*db, c, /*random=*/true);
  else if (c.workload == "overwrite")       run_fill(*db, c, /*random=*/true);
  else if (c.workload == "readrandom_hot")  run_readrandom(*db, c, std::min<uint64_t>(c.keys, 100'000));
  else if (c.workload == "readrandom_cold") run_readrandom(*db, c, c.keys);
  else if (c.workload == "readseq")         run_readseq(*db, c);
  else die("unknown workload: " + c.workload);

  auto t1 = std::chrono::steady_clock::now();
  double secs = std::chrono::duration<double>(t1 - t0).count();
  uint64_t ops = c.ops ? c.ops : c.keys;
  std::fprintf(stdout, "workload=%s ops=%lu seconds=%.3f throughput=%.0f ops/s\n",
               c.workload.c_str(), static_cast<unsigned long>(ops), secs, ops / secs);

  return 0;
}
