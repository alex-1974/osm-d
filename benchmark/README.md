# Benchmarks

The benchmark suite is intentionally separate from unit tests. Benchmarks answer
architecture questions; they are not release correctness checks and they are
not marketing numbers.

The general methodology and required metrics are defined in
`../docs/BENCHMARKS.md`.

## Varint microbenchmark

The first executable benchmark measures the production slice-backed
`osm.wire.WireCursor` against a benchmark-local legacy pointer reference. Both
hot paths use the same explicit inline treatment so the comparison remains
about cursor representation rather than package boundaries.

Run both available reference compilers from the repository root:

```bash
./benchmark/run-varint.sh
```

The runner defaults to DUB `allAtOnce` build mode. The `d-osm` package itself is
still a dependency build unit, so measured hot-path functions that require
cross-module inlining must express that explicitly; ADR 0008 records why this
matters for varint decoding.

Override build mode only for an explicit experiment:

```bash
D_OSM_BENCH_BUILD_MODE=separate ./benchmark/run-varint.sh
```

### Controlled CPU run

For architecture decisions, pin the benchmark to one logical CPU and keep its
SMT sibling idle if possible:

```bash
lscpu -e=CPU,CORE,SOCKET,NODE,ONLINE,MAXMHZ,MINMHZ
D_OSM_BENCH_CPU=4 ./benchmark/run-varint.sh
```

The runner prints logical CPU count, selected affinity, physical core and SMT
siblings when detectable. Compilation happens before affinity is applied; only
the benchmark binary is pinned. The runner does not change governor or turbo.

If `lm-sensors` is available, optional before/after thermal snapshots can be
printed:

```bash
D_OSM_BENCH_CPU=4 D_OSM_BENCH_SENSORS=1 ./benchmark/run-varint.sh
```

`D_OSM_BENCH_COOLDOWN=N` inserts the delay after compilation and before the
pre-benchmark thermal snapshot:

```bash
D_OSM_BENCH_CPU=4 \
D_OSM_BENCH_SENSORS=1 \
D_OSM_BENCH_COOLDOWN=30 \
./benchmark/run-varint.sh
```

### Statistical hygiene

The default benchmark performs three untimed warm-up passes and thirty timed
samples. In `--implementation=all` mode, production and pointer reference
alternate AB/BA order, producing ABBA over every pair of samples.

The benchmark reports min, p10, p50, p90 and max. `Δ80` is the robust relative
spread `(p90 - p10) / p50`; large values are a reason to investigate scheduler
noise, thermals or frequency scaling before drawing conclusions.

Pass benchmark options through the script:

```bash
./benchmark/run-varint.sh --values=2000000 --iterations=30 --samples=40
./benchmark/run-varint.sh --profile=mixed
```

For whole-process measurements:

```bash
D_OSM_BENCH_CPU=4 ./benchmark/run-varint.sh \
    --profile=mixed --implementation=production --samples=30

D_OSM_BENCH_CPU=4 ./benchmark/run-varint.sh \
    --profile=mixed --implementation=pointer-ref --samples=30
```

Input generation, allocation, correctness checks, sample sorting and reporting
are outside the timed region. Before timing, both implementations must agree on
representative non-minimal, truncated, overflow and maximum-value encodings.

This benchmark measures only in-memory unsigned varint decoding. It does **not**
measure file I/O, decompression, PBF framing, DenseNodes, validation or complete
OSM parsing.

`benchmark/data/`, `benchmark/results/` and `benchmark/bin/` are intentionally
ignored. Dataset metadata and hashes belong in a future tracked `datasets.toml`;
large extracts do not belong in Git.

## DenseNodes microbenchmark

`micro/dense_nodes.d` measures the production `decodeDenseNodes` path after
PrimitiveBlock/PrimitiveGroup layout discovery and StringTable indexing have
already completed. This isolates the entity hot path while retaining production
preflight, checked coordinate conversion and tag semantics.

Run both installed reference compilers:

```bash
./benchmark/run-dense-nodes.sh
```

For architecture decisions, use the same controlled environment as the varint
benchmark. On the current development laptop a typical controlled run is:

```bash
D_OSM_BENCH_CPU=4 \
D_OSM_BENCH_SENSORS=1 \
D_OSM_BENCH_COOLDOWN=30 \
./benchmark/run-dense-nodes.sh
```

The deterministic synthetic profiles are:

- `tagless`: no `keys_vals` stream;
- `typical`: two tags per node;
- `rich`: eight tags per node;
- `mixed`: deterministic 0/1/2/3/4-tag mixture.

The sink paths are:

- `coordinates`: consume only ID and exact nanodegree coordinates;
- `tag-ids`: additionally traverse every tag and consume StringTable IDs;
- `tag-bytes`: additionally touch borrowed key/value bytes.

`decodeDenseNodes` always performs its normal full preflight. Therefore the
`coordinates` path on a tagged workload still includes validation and creation
of per-node tag ranges; use the `tagless`/`coordinates` combination as the
cleanest coordinate-core baseline.

When all three paths are measured in one process, sample order rotates through
all six permutations. Reported `MiB/s(group)` is serialized in-memory
PrimitiveGroup throughput, not compressed-file or end-to-end PBF throughput.

Examples:

```bash
./benchmark/run-dense-nodes.sh --profile=tagless --path=coordinates
./benchmark/run-dense-nodes.sh --profile=typical --path=all
./benchmark/run-dense-nodes.sh --nodes=500000 --iterations=8 --samples=40
```

Workload generation, structural layout decoding, StringTable index allocation,
correctness validation, sorting and reporting are outside the timed region.

### Semantically matched C++ reference

`reference/dense_nodes_cpp.cpp` is a C++20 reference for the same canonical
no-DenseInfo workloads used by `micro/dense_nodes.d`. It intentionally performs
the same integrity work that materially affects the timed D hot path: complete
`keys_vals` preflight before emission, checked delta accumulation, checked exact
coordinate conversion, per-node tag partitioning, borrowed StringTable lookup,
and the same three observable checksum sinks.

The reference is deliberately **not** libosmium. Its purpose is to answer the
narrow compiler/language question before an implementation-level comparison is
made. A faster implementation that performs less validation would not establish
that C++ is faster than D for the same contract.

Run Clang and GCC if both are installed:

```bash
D_OSM_BENCH_CPU=4 \
D_OSM_BENCH_SENSORS=1 \
D_OSM_BENCH_COOLDOWN=30 \
./benchmark/run-dense-nodes-cpp.sh
```

For the primary language comparison, use LDC versus Clang with their normal
release optimization levels and **without** architecture-specific flags:

```bash
D_OSM_BENCH_COMPILERS=ldc2 \
D_OSM_BENCH_CPU=4 \
D_OSM_BENCH_SENSORS=1 \
D_OSM_BENCH_COOLDOWN=30 \
./benchmark/run-dense-nodes.sh

D_OSM_CPP_COMPILERS=clang++ \
D_OSM_BENCH_CPU=4 \
D_OSM_BENCH_SENSORS=1 \
D_OSM_BENCH_COOLDOWN=30 \
./benchmark/run-dense-nodes-cpp.sh
```

For every compared profile/path, verify that `nodes`, `tags`, `group-bytes` and
`checksum` match. The first performance target is `D p50 / C++ p50 <= 1.0`.
Differences must be investigated before changing representation or adding
benchmark-only fast paths.

The initial C++ reference intentionally refuses DenseInfo-bearing workloads.
Once the D benchmark gains metadata profiles, the C++ reference must implement
the same DenseInfo preflight and emission contract before those profiles may be
compared.
