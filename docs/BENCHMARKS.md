# Benchmark Methodology

## Purpose

Benchmarks answer specific architecture questions. They are not marketing
numbers.

Every benchmark must state what work is included: I/O, decompression,
validation, materialization, output serialization and store construction.

## Dataset classes

Use immutable snapshots identified by cryptographic hash.

| Class | Purpose |
| --- | --- |
| tiny | microbenchmarks, regression and malformed fixtures |
| small | fast local end-to-end runs |
| city | primary editor-scale workload |
| country | scaling and stress |
| larger | optional stress/throughput runs |

Suggested public extracts can be selected later. Dataset identity must never be
"latest" in a published comparison.

## Required scenarios

### decode-count

```text
PBF -> complete decode -> integrity checks -> count nodes/ways/relations/tags
```

No model materialization and no textual output. This is the main parser
comparison scenario.

### validate

Full structural and OSM-element validation, with results discarded.

### materialize

```text
PBF -> validated borrowed views -> owned model
```

Measures allocation strategy rather than pure decoding.

### city-store-build

```text
PBF -> validated views -> complete compact editable store
```

This is the most important application benchmark for the future editor.

### roundtrip

```text
PBF -> model/raw representation -> PBF
```

Measure both throughput and semantic equality.

## First executable microbenchmark: varint

`benchmark/micro/varint.d` establishes the first hot-path baseline. After the
cursor decision in ADR 0008, it compares the production slice-backed
`WireCursor` against a benchmark-local legacy pointer reference. Both hot paths
receive equivalent explicit inline treatment so library-boundary effects do not
masquerade as cursor-representation effects.

The benchmark uses four deterministic synthetic profiles:

- `one-byte`: all values encode in one byte;
- `two-byte`: all values encode in exactly two bytes;
- `mixed`: a deterministic small-value-heavy distribution intended to exercise
  realistic branch diversity without claiming to reproduce a particular OSM
  extract;
- `long`: values with bit 63 set, therefore exercising ten-byte uint64 varints.

For each implementation and profile, input generation and validation occur
outside the timed region. Each timed sample decodes the complete buffer several
times and consumes decoded values into an observable checksum. Untimed warm-up
passes precede measurement. Paired comparisons alternate AB/BA order, producing
ABBA over every two samples.

Report min, p10, p50, p90 and max rather than a single timing. The robust
relative spread `(p90 - p10) / p50` is reported as `Δ80`; unexpectedly large
spread is a reason to investigate scheduler noise, thermals or CPU frequency
behaviour before drawing architectural conclusions.

### Cursor decision baseline

The final fair cursor comparison used LDC 1.41.0 (DMD frontend 2.111.0, LLVM
19.1.7), CPU affinity to one logical CPU, 1,000,000 mixed-profile values,
20 decode iterations per sample, 30 samples, three warm-up passes and a
30-second post-build cooldown.

| Candidate | p50 ns/value | Mvalues/s | p10 | p90 | Δ80 |
| --- | ---: | ---: | ---: | ---: | ---: |
| pointer + explicit inline | 4.861 | 205.71 | 4.745 | 5.113 | 7.6% |
| slice + explicit inline | 4.699 | 212.80 | 4.553 | 4.975 | 9.0% |

The approximately 3.3% median slice advantage is treated as performance parity
because the distributions overlap and the laptop reached its package thermal
limit by the end of the run. The architectural decision therefore rests on the
slice retaining equal performance while substantially reducing the
`@system`/`@trusted` surface.

A separate experiment showed that *without* explicit cross-module inlining,
both library implementations were about twice as slow as an equivalent
benchmark-local hot path. Explicit inlining at measured hot-path boundaries is
therefore part of the current performance contract; it is not a general rule
for unrelated functions.

Run both installed compilers:

```bash
./benchmark/run-varint.sh
```

Published baseline results must include the full command and compiler versions.
The synthetic microbenchmark is only an architecture probe; later trace-driven
and end-to-end PBF benchmarks take precedence for production decisions.

## Microbenchmarks

At minimum:

- unsigned varint decode;
- ZigZag decode;
- checked delta accumulation;
- packed versus segmented repeated fields;
- StringTable indexing and lookup;
- DenseNodes without tags;
- DenseNodes with tags;
- DenseInfo;
- arena allocation/reset;
- ordered merge overhead.

## Metrics

Record at least:

- wall-clock time;
- CPU time;
- elements/s;
- compressed input MB/s;
- peak RSS;
- allocations where measurable;
- bytes allocated where measurable;
- thread count;
- page faults when useful;
- output size for writer tests.

## Scaling

Run significant workloads at multiple thread counts, normally:

```text
1, 2, 4, 8, ... up to useful physical/logical core counts
```

Single-thread results are mandatory. Parallel speed alone can hide an
inefficient decoder.

## Reference implementations

The first reference set should include:

- libosmium / osmium-tool for native OSM processing;
- one or more fast specialized PBF implementations when an equivalent workload
  can be constructed;
- later, editor/store-oriented systems where the compared operation is truly
  equivalent.

Do not compare `parse` on one implementation with `parse + text serialization`
on another and call it parser throughput.

## Controlled microbenchmark environment

For nanosecond-scale CPU microbenchmarks:

- pin the process to one logical CPU for architecture comparisons;
- identify the physical core and SMT sibling, and keep the sibling idle when
  practical;
- warm the benchmark before collecting samples;
- balance comparison order (AB/BA for two candidates, full permutation
  rotation for three, or equivalent) instead of always measuring one
  implementation first;
- collect enough samples to report robust quantiles, not only a single run;
- keep normal turbo/governor settings for realistic measurements, but observe
  frequency and thermals and label any deliberately fixed-frequency run;
- when compilation itself heats the package, apply any requested cooldown after
  the build and record thermals immediately before the timed process;
- repeat suspicious results as separate-process runs to detect cache or branch
  predictor interactions between implementations.

A microbenchmark with unstable p10/p90 spread is diagnostic evidence, not a
basis for changing a hot-path representation.

## Reproducibility

Each benchmark result records:

```text
git commit
compiler and version
compiler flags
OS/kernel
CPU
RAM
storage/filesystem
thread count
dataset name
SHA-256
dataset compressed size
benchmark command
```

Warm-cache and cold-cache measurements must be identified separately.

## Regression policy

Performance changes above a threshold to be fixed after the baseline suite is
stable require investigation. Correctness regressions always block release;
performance never overrides integrity.

## DenseNodes hot-path baseline

`benchmark/micro/dense_nodes.d` is the first entity-level production
microbenchmark. It measures the public `decodeDenseNodes` path, not a
benchmark-only decoder. PrimitiveBlock layout discovery, PrimitiveGroup layout
discovery and StringTable index construction are completed once before timing;
DenseNodes preflight, checked delta/coordinate decoding, per-node tag-range
construction and the selected sink work are timed.

Four deterministic synthetic profiles separate major workload shapes:

| Profile | Tags per node | Purpose |
| --- | ---: | --- |
| `tagless` | 0 | coordinate/delta baseline and empty-`keys_vals` fast path |
| `typical` | 2 | common lightly tagged node workload |
| `rich` | 8 | tag traversal and StringTable pressure |
| `mixed` | 0–4 | deterministic branch/length diversity |

Three sink paths answer different questions:

| Path | Sink work |
| --- | --- |
| `coordinates` | consume node ID and exact nanodegree coordinates only |
| `tag-ids` | additionally traverse every borrowed tag and consume key/value SIDs |
| `tag-bytes` | additionally touch borrowed key/value string bytes |

The decoder itself always performs production tag preflight. Consequently,
`coordinates` on a tagged profile is **not** a tag-free alternate decoder; the
`tagless` + `coordinates` result is the cleanest core baseline. This deliberate
choice prevents a benchmark-only fast path from influencing architecture.

When all sink paths are run together, their order rotates through all six
permutations across samples to reduce thermal/cache ordering bias. The same
min/p10/p50/p90/max and Δ80 rules used by the varint benchmark apply.

Run a controlled baseline with LDC as the architectural reference compiler:

```bash
D_OSM_BENCH_COMPILERS=ldc2 \
D_OSM_BENCH_CPU=4 \
D_OSM_BENCH_SENSORS=1 \
D_OSM_BENCH_COOLDOWN=30 \
./benchmark/run-dense-nodes.sh
```

Run DMD as a useful development comparison, but do not choose hot-path
representations from DMD alone. Before adding explicit `pragma(inline, true)`
or changing data representation, repeat suspicious results in a separate
process/path selection and confirm the effect with LDC.

The benchmark reports ns/node, Mnodes/s and `MiB/s(group)`. The byte-throughput
number uses serialized in-memory PrimitiveGroup bytes and must never be
presented as compressed PBF I/O or whole-parser throughput.
