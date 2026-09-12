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
