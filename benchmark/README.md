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

## Regular Node microbenchmark

`micro/regular_nodes.d` measures the production `decodeNodes` path after
PrimitiveBlock/PrimitiveGroup layout discovery and StringTable indexing have
already completed. The timed path deliberately retains the current correctness
architecture: every regular Node in the group is semantically preflighted before
any sink call, then the group is parsed a second time for TagRange construction
and NodeView emission.

Run both installed reference compilers:

```bash
./benchmark/run-regular-nodes.sh
```

For architecture decisions, use the same controlled environment as DenseNodes.
For the primary LDC baseline on the current development laptop:

```bash
D_OSM_BENCH_COMPILERS=ldc2 \
D_OSM_BENCH_CPU=4 \
D_OSM_BENCH_SENSORS=1 \
D_OSM_BENCH_COOLDOWN=30 \
./benchmark/run-regular-nodes.sh
```

When LDC-specific `DFLAGS` such as full LTO are supplied, select `ldc2`
explicitly so those flags are not passed to DMD.

The deterministic synthetic profiles are:

- `tagless`: no tags and no Info metadata;
- `typical`: two tags per Node, no Info metadata;
- `typical-info`: two tags plus version/timestamp/changeset/uid/user/visible;
- `rich`: eight tags plus the same Info metadata.

Regular Node IDs and coordinates are direct `sint64` values rather than DenseNodes
deltas. The generated values intentionally have realistic multi-byte varint
widths; coordinates are converted by the production granularity/offset logic.
Tags use canonical packed `keys` and `vals` arrays. Metadata uses one canonical
Info occurrence per metadata-bearing Node; protobuf merge/alternate-wire-form
coverage remains a correctness-test concern rather than a benchmark workload.

The sink paths match the DenseNodes benchmark:

- `coordinates`: consume ID and exact nanodegree coordinates;
- `tag-ids`: additionally traverse every tag and consume StringTable IDs;
- `tag-bytes`: additionally touch borrowed key/value bytes.

For metadata-bearing profiles every sink also consumes the decoded Info fields
and borrowed username bytes. This keeps metadata observable without adding a
fourth sink path.

When all three paths are measured in one process, sample order rotates through
all six permutations. Reported `MiB/s(group)` is serialized in-memory
PrimitiveGroup throughput, not compressed-file or end-to-end PBF throughput.

Examples:

```bash
./benchmark/run-regular-nodes.sh --profile=tagless --path=coordinates
./benchmark/run-regular-nodes.sh --profile=typical-info --path=all
./benchmark/run-regular-nodes.sh --nodes=200000 --iterations=3 --samples=40
```

Workload generation, structural layout decoding, StringTable index allocation,
initial correctness validation, sorting and reporting are outside the timed
region. The initial benchmark is a baseline for commit `eab2f9d`; it must not
introduce a scalar fast path, cached first-pass representation or specialized
regular-Node emitter. Those are separate architecture changes that require
measurement against this baseline.

### Regular Node stage diagnostics

`regular-node-stages` is a diagnostic companion to the regular-Node baseline.
It does not change the production decoder. Instead, the benchmark build enables
benchmark-local mirrors of the current private `NodeMessageCursor` traversal and
first semantic `parseNode` pass, then compares them with the real production
`decodeNodes` coordinates path.

The three stages are:

- `group-scan`: traverse the PrimitiveGroup framing and locate every regular
  Node payload, without parsing Node fields;
- `semantic-preflight`: perform one complete benchmark-local mirror of the
  current first production pass, including required-field checks, exact checked
  coordinate conversion, merged Info validation and normal-tag validation;
- `full-decode`: call the production `decodeNodes` implementation and consume
  coordinates plus Info through the same coordinates sink as the baseline.

The first two stages intentionally mirror private implementation details and are
therefore diagnostic probes, not public parser APIs. `full-decode` remains the
production truth. The reported derived `parse+validate` and `post-preflight`
figures are differences of p50 medians, not independently timed stages.

Run the controlled stage suite with the same environment used for the regular
Node baseline:

```bash
D_OSM_BENCH_COMPILERS=ldc2 \
D_OSM_BENCH_CPU=4 \
D_OSM_BENCH_SENSORS=1 \
D_OSM_BENCH_COOLDOWN=30 \
./benchmark/run-regular-node-stages.sh
```

A focused run can select one profile or stage:

```bash
./benchmark/run-regular-node-stages.sh \
    --profile=typical --stage=all

./benchmark/run-regular-node-stages.sh \
    --profile=typical-info --stage=semantic-preflight
```

Use the stage benchmark to test cost hypotheses before changing `decodeNodes`.
Do not quote benchmark-local mirror stages as production throughput.

## Regular Way microbenchmark

`micro/regular_ways.d` measures the production `decodeWays` path after
PrimitiveBlock/PrimitiveGroup layout discovery and StringTable indexing have
already completed. The benchmark deliberately preserves the correctness-first
architecture of commit `476319d`: every Way is fully preflighted before any
sink call, then the group is parsed again for borrowed range construction and
WayView emission.

Run both installed reference compilers:

```bash
./benchmark/run-regular-ways.sh
```

For controlled LDC measurements use the same environment as the Node and
DenseNodes baselines:

```bash
D_OSM_BENCH_COMPILERS=ldc2 \
D_OSM_BENCH_CPU=4 \
D_OSM_BENCH_SENSORS=1 \
D_OSM_BENCH_COOLDOWN=30 \
./benchmark/run-regular-ways.sh
```

The deterministic profiles are:

- `ref-only`: eight delta-coded node refs per Way, no tags, Info, or locations;
- `typical`: eight refs plus two tags;
- `typical-info`: eight refs, two tags, and full Info metadata;
- `locations`: the `typical-info` workload plus eight aligned
  `LocationsOnWays` latitude/longitude pairs;
- `rich`: 32 refs, eight tags, full Info, and 32 aligned locations.

All sink paths consume Way identity, Info when present, and every absolute node
reference. This makes `refs` the common observable baseline. Additional work is:

- `refs`: consume only the absolute node-reference range;
- `tag-ids`: additionally traverse tags and consume StringTable IDs;
- `tag-bytes`: additionally touch borrowed tag key/value bytes;
- `locations`: additionally traverse exact nanodegree `LocationsOnWays` values.

When all four paths are measured, sample order rotates through all 24
permutations. Reported `MiB/s(group)` is serialized in-memory PrimitiveGroup
throughput, not compressed-file or end-to-end PBF/editor throughput.

Examples:

```bash
./benchmark/run-regular-ways.sh --profile=ref-only --path=refs
./benchmark/run-regular-ways.sh --profile=locations --path=locations
./benchmark/run-regular-ways.sh --ways=200000 --iterations=3 --samples=40
```

Workload generation, structural layout decoding, StringTable index allocation,
initial correctness validation, sorting and reporting are outside the timed
region. This benchmark is the performance baseline for the correctness-first
regular-Way decoder at commit `476319d`; it must not introduce a prevalidated
second pass, cached representation, geometry construction, node resolution, or
other production fast path. Those require measurement against this baseline.

### Regular Way stage diagnostics

`regular-way-stages` is a diagnostic companion to the regular-Way baseline. It
changes no production code. The benchmark build enables benchmark-local mirrors
of the current private Way message traversal and semantic preflight, plus a
candidate second pass that assumes the immutable bytes have already passed the
complete group preflight.

The four stages are:

- `group-scan`: locate every regular Way payload in the PrimitiveGroup without
  parsing Way fields;
- `semantic-preflight`: mirror one complete current `parseWay` pass, including
  required ID, merged/finalized Info, tag validation, checked delta-coded refs,
  and full `LocationsOnWays` accumulation plus exact coordinate validation;
- `prevalidated-emission`: re-decode output values and repeated-column counts,
  construct borrowed tag/ref/location ranges and consume the refs sink, while
  skipping duplicate tag StringTable validation, checked ref accumulation and
  complete location accumulation/nanodegree validation already proved by the
  semantic preflight;
- `full-decode`: call production `decodeWays` and consume the normal refs sink.

The candidate deliberately does not cache per-Way summaries and does not
allocate. It models the smallest two-pass optimization compatible with the
existing guarantee that the complete PrimitiveGroup is semantically valid
before the first observable sink call. `WayView` remains OSM-topological;
node resolution and geometry construction stay outside this benchmark.

Run with the same controlled environment as the Way production baseline:

```bash
D_OSM_BENCH_COMPILERS=ldc2 \
D_OSM_BENCH_CPU=4 \
D_OSM_BENCH_SENSORS=1 \
D_OSM_BENCH_COOLDOWN=30 \
./benchmark/run-regular-way-stages.sh
```

Focused examples:

```bash
./benchmark/run-regular-way-stages.sh \
    --profile=locations --stage=all

./benchmark/run-regular-way-stages.sh \
    --profile=rich --stage=prevalidated-emission
```

Derived `parse+validate`, `current-post`, `candidate-total` and `potential`
values subtract separately measured p50 medians. They are diagnostic estimates,
not independently timed production stages. The production `full-decode` result
remains the plausibility anchor and should stay comparable with the committed
regular-Way baseline before an architecture change is accepted.
