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

Dataset identity must never be "latest" in a published comparison.

The initial pinned real-data baseline is recorded in
`../benchmark/datasets/geofabrik-2026-09-01.tsv`. It uses dated Geofabrik
snapshots for Monaco and Liechtenstein (`small`), Bremen (`city`) and Austria
(`country`). The large PBF files remain local under ignored `benchmark/data/`
storage and are acquired or verified with `../benchmark/fetch-datasets.sh`.

SHA-256 is the authoritative benchmark identity. The manifest also records the
snapshot date, verification date, compressed byte size and Geofabrik MD5 value
as additional acquisition evidence. The optional `larger` class remains
unpinned until a concrete stress/throughput experiment requires it.

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

## DenseNodes D versus C++ semantic reference

The entity hot path has an explicit cross-language performance target: on an
equivalent workload and integrity contract, the LDC build should reach at least
C++ performance. The first quantitative criterion is:

```text
D p50 / C++ p50 <= 1.0
```

`benchmark/reference/dense_nodes_cpp.cpp` exists to make that statement
meaningful. It is a benchmark-local C++20 implementation of the same canonical
no-DenseInfo DenseNodes workload contract rather than a wrapper around a
third-party parser. It mirrors the work that materially contributes to the
production D benchmark's timed region:

- full dense-tag preflight before the first emitted node;
- packed/unpacked-capable protobuf cursors over the group/dense columns;
- checked delta accumulation;
- checked `offset + granularity * coordinate` conversion;
- explicit node/tag-count exhaustion checks;
- per-node borrowed tag ranges;
- StringTable ID validation and borrowed byte lookup;
- identical coordinate, tag-ID and tag-byte checksum sinks.

Workload generation, group layout discovery and StringTable indexing remain
outside the timed region in both languages. The deterministic workload builder
is duplicated intentionally; a valid comparison requires identical reported
node count, tag count, serialized group byte count and checksum for every
profile/path.

Use LDC versus Clang as the primary language/compiler comparison. Do not add
`-march=native`, LTO, PGO or language-specific tuning to only one candidate.
Such experiments are valuable later, but they answer a different question.
Run each candidate after compilation with the same CPU affinity, cooldown and
sample parameters, and repeat with reversed whole-process order if the result
is close or thermally noisy.

libosmium/protozero remains the separate production-implementation reference.
Its results should not be interpreted as a pure D-versus-C++ language result
unless the measured semantic work is first shown to be equivalent.

Current production D and the retained C++ semantic reference no longer perform
cycle-for-cycle equivalent coordinate arithmetic. D validates the complete
cumulative ID/coordinate streams and coordinate ranges during preflight, then
uses direct cumulative addition and affine nanodegree reconstruction during
emission. The C++ reference still repeats checked cumulative and coordinate
arithmetic while emitting nodes. It is therefore a conservative semantic
reference until its preflight/emission split is updated to match production.
Absolute current D/C++ timings must not be presented as a strict same-work
language comparison.

## Historical DenseNodes reference baseline (2026-09-13)

DenseNodes is a production hot path and has a dedicated semantic reference
benchmark. At this historical baseline the comparison was used to guide the
specialized dispatch architecture while retaining complete structural
preflight, checked arithmetic, StringTable validation and identical observable
sink/checksum semantics. Subsequent production optimizations moved redundant
per-node arithmetic checks out of emission after equivalent checks had already
succeeded during preflight, so the table below is retained as historical
evidence rather than a current same-work comparison.

Reference environment for this baseline:

```text
D compiler:       LDC 1.41.0 (DMD frontend 2.111.0, LLVM 19.1.7)
C++ compiler:     Clang 21.1.8
CPU protocol:     benchmark pinned to logical CPU 4
SMT protocol:     sibling CPU 10 offline during measurement
D workload:       200,000 nodes/profile, 5 iterations/sample,
                  30 samples, 2 warm-up iterations
Statistic:        p50 ns/node; p10/p90 and Delta80 retained for stability checks
```

The repository does not hard-code an LLVMgold location. LTO is an optional
machine-local benchmark choice; when required, supply it through `DFLAGS`, for
example on a host where the plugin path is known:

```text
DFLAGS="-flto=full -flto-binary=/path/to/LLVMgold.so" ./run-dense-nodes.sh ...
```

Historical D baseline with the specialized dispatch boundary:

| Profile / sink | D p50 ns/node | C++ p50 ns/node | D vs C++ |
| --- | ---: | ---: | ---: |
| tagless / coordinates | 27.310 | 16.311 | +67.4% |
| tagless / tag IDs | 27.592 | 15.356 | +79.7% |
| tagless / tag bytes | 26.580 | 15.455 | +72.0% |
| typical / coordinates | 80.375 | 76.895 | +4.5% |
| typical / tag IDs | 102.187 | 99.971 | +2.2% |
| typical / tag bytes | 112.276 | 107.988 | +4.0% |
| rich / coordinates | 160.502 | 195.440 | -17.9% |
| rich / tag IDs | 230.828 | 291.842 | -20.9% |
| rich / tag bytes | 270.930 | 326.731 | -17.1% |
| mixed / coordinates | 70.449 | 70.248 | +0.3% |
| mixed / tag IDs | 87.987 | 91.776 | -4.1% |
| mixed / tag bytes | 95.380 | 97.781 | -2.5% |

Negative percentages mean that D is faster. The realistic tagged profiles are
therefore at C++ reference performance or better overall; the deliberately
minimal tagless case remains slower and is tracked as a known microbenchmark
outlier rather than being allowed to distort the general decoder architecture.

The final code-generation boundary is deliberate: `decodeDenseNodes` performs
validation and runtime capability selection, then calls a non-inlined
compile-time-specialized dispatch wrapper. The selected `emitDenseNodes`
specialization is inlined into that wrapper. This prevents all four
`HasTags`/`HasInfo` variants from being expanded into one dispatcher while
retaining full optimization of the selected per-node hot loop.

Permanent diagnostic microbenchmarks retain the coordinate-stage and varint-core
probes because they isolate reusable wire/coordinate costs. The temporary
E0--E4 tagless breakdown and disassembly probe are not part of the maintained
benchmark suite.


## DenseNodes scalar hot-path research milestone (2026-09-15)

The follow-up A2/A3 campaign targeted the remaining scalar cost in validated
DenseNodes emission. Correctness and malformed-input behavior remained
non-negotiable: each accepted optimization removed work only when the same
semantic condition had already been established by the validated layout or
preflight over the same encoded streams.

The campaign used LDC 1.41.0 (DMD frontend 2.111.0, LLVM 19.1.7) as the
performance compiler. Controlled runs pinned the benchmark to logical CPU 5,
disabled turbo and offlined SMT sibling CPU 11. Background backup processes
were suspended for the measurement window. Checksums were required to match
for every compared workload.

The following values are representative controlled tagless/coordinates
snapshots from the research sequence. They document the scale of the progression
but are not a substitute for the paired A/B decision for each individual
change; the measurements were collected in separate controlled sessions.

| Stage | Commit | Change | tagless / coordinates |
| --- | --- | --- | ---: |
| pre-A2 reference | `deb1419` | validated emission before arithmetic deduplication | ~46.843 ns/node |
| A2a | `948dbf7` | remove duplicate per-node checked coordinate `offset + granularity * value` arithmetic after range preflight | ~23.334 ns/node |
| A2b | `dfcd3dc` | remove duplicate per-node checked cumulative ID/latitude/longitude additions already validated over the same streams | ~14.047 ns/node |
| A3a-1 | `fb729e0` | stop rewriting successful `PbfStatus` inside the private Dense column cursor | ~12.318 ns/node |
| A3a-2i | `20e78ca` | use a package-internal failure-only `sint64` decoder in the Dense column cursor | ~11.555 ns/node |

Across those representative endpoints the minimal coordinate-core production
path fell by about 75.3%, corresponding to roughly 4.05 times the throughput of
the pre-A2 reference. This number describes the synthetic tagless coordinate
microbenchmark only; it is not whole-file PBF throughput.

The directly paired decisions were also checked on tagged profiles. Removing
duplicate cumulative checked additions (A2b) improved the coordinate path by
about 39.8% for tagless data and by roughly 4--5% for the typical, rich and
mixed profiles. A3a-1 improved all twelve profile/path combinations in its
controlled matrix. A3a-2i retained the same DenseNodes semantics and public wire
API while removing successful `WireStatus` materialization from the two private
Dense column `sint64` decode sites.

A3a-2i deliberately keeps the failure-only decoder package-internal. Public
`readVarint64` and `readSVarint64` retain their success/failure `WireStatus`
contract. The final implementation was verified to produce exactly the same
DenseNodes benchmark binary as the measured experimental winner:

```text
SHA-256:
9094dddfa44e45d82c860ab8ab737939ca837652b6fa7937bee819c6ed514cd4
```

All twelve `dispatchDenseNodes!(HasTags, HasInfo, Sink)` benchmark
specializations were code-generation equivalent between the experimental and
final implementations. The final source also retained passing unit tests across
24 modules.

Two attempted slow-path extractions were rejected despite large static code-size
reductions:

| Experiment | Static effect | Runtime effect | Decision |
| --- | --- | --- | --- |
| A3b-1 | tagless dispatcher ~16,925 -> 9,429 bytes (-44.3%) | ~7.5% slower | REJECT |
| A3b-2 | tagless dispatcher ~16,925 -> 10,490 bytes (-38.0%) | ~8.8% slower; substantially more retired branches and lower IPC | REJECT |

The rejected A3b experiments are important negative evidence: reducing static
instruction footprint did not automatically improve this one-byte-varint
workload. The extracted slow path introduced control-flow costs on the common
path. Future code-size work must therefore be evaluated with runtime counters,
not accepted from size reduction alone.

The arithmetic optimizations rely on a validated-layout precondition. The
backing `const(ubyte)[]` bytes are validated before emission and must still
correspond to that validated layout when decoding occurs; they are not described
as immutable. Fabricating a validated layout or mutating aliased backing storage
after validation violates that precondition.

After A3a-2i the current production code was profiled again before selecting
the next experiment. The fixed LDC benchmark binary retained SHA-256
`9094dddfa44e45d82c860ab8ab737939ca837652b6fa7937bee819c6ed514cd4`.
The tagless coordinate path remained stable at about 11.55 ns/node, and cycle
sampling again placed nearly all measured execution inside the specialized
DenseNodes dispatcher. No single remaining decoder instruction dominated the
profile; sampled work was distributed across cursor bookkeeping, one-byte
`sint64`/ZigZag handling, coordinate arithmetic and benchmark sink work.

### A4a: per-node Dense column presence checks

A4a tested whether emission could omit the `hasId`/`hasLat`/`hasLon` checks
after successful layout validation. The semantic premise is valid under the
same validated-layout precondition used by the accepted A2 changes:
`decodePrimitiveGroupLayout()` scans every ID, latitude and longitude value,
records their counts, requires the three counts to be equal, and exposes the
validated ID count as `DenseNodesLayout.nodeCount`. `emitDenseNodes()` then
requests exactly that many values from each of the same merged streams.

The experimental implementation therefore retained all cursor and wire-decode
failure handling but stopped testing the successful per-value presence flags.
It passed the full unit-test suite (24 modules) and reduced the tagless
coordinate dispatcher statically:

| Metric | Baseline | A4a | Change |
| --- | ---: | ---: | ---: |
| dispatcher size | 15,646 bytes | 15,573 bytes | -73 bytes |
| static instructions | 3,067 | 3,057 | -10 |
| `mov` family | 1,234 | 1,228 | -6 |
| conditional jumps | 352 | 351 | -1 |
| unconditional jumps | 111 | 110 | -1 |
| calls | 78 | 78 | 0 |

Despite the smaller static hot loop, a controlled A-B-B-A run on
tagless/coordinates was clearly slower:

| Comparison | A4a vs baseline |
| --- | ---: |
| mean p50 | +5.23% ns/node |
| B1 / A1 | +4.34% |
| B2 / A2 | +6.12% |

All runs produced the same checksum. A second source formulation using three
independent ignored presence variables produced the same candidate benchmark
binary (`59876c2fde8205e4c251b4c1c1fa493ae1ac8b603741219f5e52691aa1daa949`),
so reuse of one ignored output variable was not responsible for the regression.

A fixed-binary hardware-counter A-B-B-A run confirmed that the candidate
retired less work but executed it less efficiently:

| Counter | Baseline mean | A4a mean | Change |
| --- | ---: | ---: | ---: |
| cycles | 3,119,307,699.5 | 3,276,571,917.5 | +5.04% |
| instructions | 12,511,905,281 | 11,896,309,526 | -4.92% |
| branches | 858,780,541 | 756,180,905 | -11.95% |
| IPC | 4.011 | 3.631 | -9.5% |

Branch misses remained extremely small in absolute terms and are not used to
explain the regression. The measurements establish that removing the presence
checks reduced retired instructions and branches while increasing cycles and
lowering IPC. They do not identify a unique microarchitectural cause; code
layout, scheduling and dependency effects remain possible explanations rather
than demonstrated ones.

A4a is therefore **REJECTED as a performance change** despite its valid
semantic premise and smaller generated code. The experiment reinforces the
earlier A3b result: static simplification of this hot loop must not be accepted
without controlled runtime evidence.


### A4d: publish the completed DenseNodes node count once

Fresh profiling also showed that the successful emission loop updated
`DenseNodeDecodeSummary.nodeCount` once per emitted node. That value is already
fixed by the validated layout: `DenseNodesLayout.nodeCount` is established
before emission, and `DenseNodeDecodeSummary` represents the result of a
successfully completed decode rather than a partial-progress interface.

A4d therefore removed the per-node `++summary.nodeCount` update and publishes

```d
summary.nodeCount = group.dense.nodeCount;
```

once after successful completion of all emission and final consistency checks.
The public contract was made explicit at the same time: summary fields are
contractually valid only when `decodeDenseNodes()` returns `true`; callers must
not interpret them as partial progress after a failed decode.

The source change passed the full unit-test suite (24 modules). The final
documented source rebuilt to exactly the benchmark binary used for the
performance decision:

```text
SHA-256:
b9466c315aef00a82a454d27a0909837f4b3ef16a28145dc510a769322e6429c
```

A controlled fixed-binary A-B-B-A run on tagless/coordinates showed a consistent
improvement:

| Comparison | A4d vs baseline |
| --- | ---: |
| mean p50 | -2.83% ns/node |
| B1 / A1 | -2.60% |
| B2 / A2 | -3.05% |
| throughput from mean p50 | +2.91% |

All four runs produced the same checksum. A separate fixed-binary hardware
counter A-B-B-A run supported the same mechanism:

| Counter | Baseline mean | A4d mean | Change |
| --- | ---: | ---: | ---: |
| cycles | 3,122,993,885.5 | 3,052,591,816.0 | -2.25% |
| instructions | 12,511,902,278.5 | 12,306,705,521.0 | -1.64% |
| branches | 858,779,935.5 | 858,781,226.5 | ~0.00% |
| IPC | 4.0064 | 4.0316 | +0.63% |

Unlike A4a, A4d therefore reduced retired work and cycles without degrading
execution efficiency in the targeted minimal hot path.

The full twelve-combination profile/path matrix was more mixed than the
tagless result: nine combinations improved in both paired comparisons, two were
slower in both comparisons, and one had mixed direction. Checksums matched in
all combinations. In particular, the ordinary timing matrix showed small
apparent regressions for `typical/coordinates` and `rich/coordinates`.

Those timing-only regressions were not confirmed as a stable execution-cost
regression by targeted fixed-binary counter runs. For `typical/coordinates`,
A4d reduced cycles by about 0.64%, instructions by about 2.98%, and branches by
about 5.89%. For `typical/tag-ids`, it reduced cycles by about 1.74%,
instructions by about 1.42%, and branches by about 5.01%. Branch-miss counts
remained tiny in absolute terms and are not used to explain the result.

Static inspection of the tagged `HasTags=true, HasInfo=false` dispatchers also
showed broader code-generation simplification than the single removed memory
increment alone:

| Dispatcher | Metric | Baseline | A4d | Change |
| --- | --- | ---: | ---: | ---: |
| coordinates | size | 23,915 bytes | 23,678 bytes | -237 bytes |
| coordinates | static instructions | 4,433 | 4,387 | -46 |
| coordinates | `mov` family | 1,896 | 1,861 | -35 |
| coordinates | unconditional jumps | 169 | 163 | -6 |
| coordinates | calls | 124 | 123 | -1 |
| tag IDs | size | 23,915 bytes | 23,762 bytes | -153 bytes |
| tag IDs | static instructions | 4,436 | 4,405 | -31 |
| tag IDs | `mov` family | 1,899 | 1,876 | -23 |
| tag IDs | unconditional jumps | 171 | 166 | -5 |
| tag IDs | calls | 126 | 126 | 0 |

The intended per-node summary memory increment disappears in both dispatchers.
The source change also enables wider generated-code simplification, but the
measurements do not isolate a unique LDC/LLVM cause. Alias analysis, register
allocation, control-flow simplification, code layout, or a combination of
effects may contribute; none is claimed as the demonstrated sole mechanism.

A4d is therefore **KEPT**. The decision rests on the controlled tagless A-B-B-A
win, matching hardware-counter evidence, successful targeted tagged counter
runs, passing correctness tests, and exact final-binary identity. The mixed
twelve-combination timing matrix is retained as part of the evidence rather
than being hidden or interpreted as uniformly positive.

### A5a: DenseNodes countdown emission loop

Post-A4d profiling showed that the tagless/coordinates specialization still
spent measurable time in its loop-control sequence. The production loop

```d
foreach (_; 0 .. group.dense.nodeCount)
```

does not use its iteration index semantically. A5a therefore tested the
equivalent countdown form

```d
for (size_t remaining = group.dense.nodeCount; remaining != 0; --remaining)
```

as an isolated loop-control experiment. No cursor, validation, sink, summary,
tag, DenseInfo, or `nodeCount` publication logic changed.

The experiment passed the full unit-test suite (24 modules). For the
tagless/coordinates dispatcher, LDC generated a smaller function:

| Metric | Baseline | A5a | Change |
| --- | ---: | ---: | ---: |
| dispatcher size | 15,673 bytes | 15,609 bytes | -64 bytes |
| static instructions | 3,067 | 3,059 | -8 |
| `mov` family | 1,233 | 1,230 | -3 |
| `inc` family | 2 | 1 | -1 |
| `dec` family | 0 | 1 | +1 |
| `cmp` family | 122 | 121 | -1 |
| conditional jumps | 352 | 352 | 0 |
| unconditional jumps | 111 | 110 | -1 |
| calls | 79 | 79 | 0 |

The intended loop-control change was therefore present in generated code rather
than optimized back into the previous formulation. Both
`DenseNodesLayout.nodeCount` call sites also remained present, so A5a did not
accidentally include a separate `nodeCount`-hoisting optimization.

A controlled fixed-binary A-B-B-A run on tagless/coordinates initially showed
a strong and highly consistent local improvement:

| Comparison | A5a vs baseline |
| --- | ---: |
| mean p50 | -2.620% ns/node |
| B1 / A1 | -2.620% |
| B2 / A2 | -2.620% |
| throughput from mean p50 | +2.690% |

All four runs produced the same checksum.

A separate fixed-binary hardware-counter A-B-B-A run supported that local
result:

| Counter | Baseline mean | A5a mean | Change |
| --- | ---: | ---: | ---: |
| cycles | 3,052,656,503.0 | 2,987,382,857.0 | -2.138% |
| instructions | 12,306,699,957.5 | 11,998,904,309.5 | -2.501% |
| branches | 858,780,144.5 | 858,780,900.0 | ~0.000% |
| IPC | 4.0315 | 4.0165 | -0.371% |

Cycle reductions were consistent in both counter pairs (-2.119% and -2.158%).
Branch-miss counts increased substantially in relative terms, but remained
small compared with roughly 859 million retired branches and are treated only
as diagnostic evidence rather than as an explanation of the result.

The complete twelve-combination profile/path matrix reversed the local
conclusion:

| Profile | Path | Mean p50 change | B1 / A1 | B2 / A2 | Direction |
| --- | --- | ---: | ---: | ---: | --- |
| tagless | coordinates | -2.609% | -2.575% | -2.643% | win |
| tagless | tag IDs | +23.527% | +23.913% | +23.143% | loss |
| tagless | tag bytes | -2.398% | -2.644% | -2.151% | win |
| typical | coordinates | -0.004% | +0.020% | -0.027% | mixed |
| typical | tag IDs | +1.163% | +1.165% | +1.162% | loss |
| typical | tag bytes | +0.937% | +1.389% | +0.488% | loss |
| rich | coordinates | -0.063% | +0.047% | -0.174% | mixed |
| rich | tag IDs | +2.122% | +2.232% | +2.013% | loss |
| rich | tag bytes | +2.644% | +1.589% | +3.699% | loss |
| mixed | coordinates | +0.366% | +0.577% | +0.155% | loss |
| mixed | tag IDs | +0.599% | +9.117% | -7.209% | mixed |
| mixed | tag bytes | +1.621% | +1.648% | +1.593% | loss |

Checksums matched in every combination. Overall, only two combinations improved
in both paired comparisons, seven were slower in both comparisons, and three
had mixed direction. The median combination delta was +0.768% ns/node. The
large +23.527% regression for tagless/tag-ids is especially important because
the serialized input remains tagless: changing only the sink instantiation is
sufficient for LDC to generate very different performance from the same source
loop transformation.

#### A5a frontend-placement diagnosis

The unusually large tagless/tag-ids regression was investigated separately
rather than attributed to the countdown source form from timing alone. Within
each build, normalized disassembly of the three tagless sink/template
dispatchers was structurally identical after absolute addresses and symbol
names were removed.

The three A5a dispatchers all had size 15,609 bytes and the same normalized
SHA-256:

```text
911a69074da34b09ba0ec62cbedefe1e8b1601136bbd9e00715b2f21f3f52000
```

The corresponding baseline dispatchers were likewise mutually identical
within their build, with size 15,673 bytes and normalized SHA-256:

```text
2f506f76e64f998bb68ca16208a33e61bd0f4aef157e19e26710cf9cb276a4db
```

This made absolute code placement a directly testable variable.

GNU `ld.bfd`, reached through LDC, accepted

```text
-L--section-start=.text=<address>
```

without changing the normalized dispatcher code. A controlled A5a sweep moved
`.text` in 16-byte increments from `0x25990` through `0x25a80`, producing
sixteen binaries with identical normalized dispatcher code but different
absolute addresses.

The tagless/tag-ids path showed a deterministic placement pattern:

| TagId dispatcher phase | Representative cycles | `IDQ_UOPS_NOT_DELIVERED.CORE` / cycle | Behavior |
| --- | ---: | ---: | --- |
| `mod 64 = 16 or 48` | 2.965-2.971 billion | 0.011-0.014 | fast |
| `mod 64 = 0` | 3.458-3.462 billion | 0.583-0.587 | intermediate |
| `mod 64 = 32` | 3.765-3.767 billion | 0.847-0.848 | slow |

Across those code-identical A5a binaries, the maximum/minimum cycle spread was
**27.08%**. The original A5a tag-ids placement belonged to the slow
`mod 64 = 32` class.

The same sixteen-phase experiment on the unchanged production baseline did not
show comparable sensitivity. Its cycle spread was only **1.12%**, with all
measurements remaining close to 3.04-3.07 billion cycles.

Comparing baseline and A5a at identical `.text` phases made the contrast
explicit:

| A5a TagId phase | A5a versus baseline |
| --- | ---: |
| `mod 64 = 16 or 48` | approximately -2.2% to -2.9% |
| `mod 64 = 0` | approximately +12.6% to +13.2% |
| `mod 64 = 32` | approximately +23.3% to +23.5% |

The strong placement sensitivity is therefore not a general property of the
DenseNodes benchmark or of the baseline dispatcher. It is a property of the
machine-code layout generated for A5a.

Hardware frontend counters independently matched this result. In the original
slow A5a tag-ids placement, IPC fell to about 3.19 while
`IDQ_UOPS_NOT_DELIVERED.CORE` rose to about 0.85 per cycle. Earlier frontend
counter runs also showed a large shift away from DSB delivery toward MITE
delivery, while backend resource stalls decreased rather than increased.
Ordinary L1 instruction-cache activity was too small to account for the cycle
difference.

The test CPU was an Intel Core i7-9750H with CPUID family/model/stepping
`06_9E_A` and microcode revision `0xfa`. LDC 1.41.0 / LLVM 19.1.7 exposes the
backend option

```text
--x86-branches-within-32B-boundaries
```

whose help text describes it as aligning selected instructions to mitigate the
negative performance impact of Intel's microcode update for erratum `skx102`.

Static disassembly of the unmitigated A5a variants showed control-transfer
instructions that crossed or ended on 32-byte boundaries. The analyzed slow
and intermediate placements each had 37 such hazards in the selected repeated
region, while the two fast placements had 33.

Hazard count alone did not explain the three observed performance levels: the
slow and intermediate placements had the same analyzed hazard set despite
materially different runtime. The experiment therefore does not identify one
specific offending branch, nor does it establish simple boundary-hazard count
as a sufficient performance model.

The decisive intervention was to rebuild A5a with LLVM's explicit JCC
mitigation enabled. Four representative placements were tested: the former
slow `mod 64 = 32`, intermediate `mod 64 = 0`, and the two fast
`mod 64 = 16/48` classes.

LLVM padding increased the TagId dispatcher from 15,609 to 16,306 bytes. A
static scan of the mitigated binaries found zero jump instructions crossing or
ending on a 32-byte boundary in all four cases.

The runtime effect was correspondingly large:

| `.text` phase | Unmitigated A5a vs baseline | Mitigated A5a vs baseline | Mitigated IDQ-undel/cycle | Mitigated MITE share |
| --- | ---: | ---: | ---: | ---: |
| `0x25990` | +23.46% | +0.72% | 0.0187 | 0.56% |
| `0x259a0` | -2.50% | +1.09% | 0.0189 | 0.56% |
| `0x259b0` | +12.74% | +0.23% | 0.0167 | 0.50% |
| `0x259c0` | -2.93% | +0.53% | 0.0164 | 0.50% |

The unmitigated four-phase A5a cycle spread was **27.06%**. With LLVM's JCC
mitigation it fell to **0.11%**, a **99.60% reduction**. Mitigated IPC was
4.037-4.041 for all four placements, and DSB delivery again overwhelmingly
dominated MITE delivery.

This intervention provides strong causal evidence that the dominant A5a
placement regression is an interaction between the A5a-generated branch
layout and the Intel JCC/32-byte-boundary microcode mitigation represented by
LLVM's `skx102` workaround.

The experiment does not identify a single responsible branch. The LLVM
mitigation also changes padding and generated-code size, so the result is not
stated as proof that one individual boundary crossing is the sole
microarchitectural cause.

The diagnostic runs were retained outside the repository at:

```text
/tmp/d-osm-a5a-phase-sweep-20260915-213159
/tmp/d-osm-baseline-phase-sweep-20260915-214304
/tmp/d-osm-a5a-jcc-20260915-222032
```

This diagnosis does not change the optimization decision. Compiler-specific
branch padding suppresses the pathological placement, but it also removes the
small advantage of the previously fast A5a phases and increases generated-code
size. More importantly, a source-level library optimization must not depend on
a fortunate code address, one CPU microcode behavior, or a particular LLVM
backend mitigation to remain broadly beneficial.

A5a is therefore **REJECTED as a general performance change**. The countdown
form is semantically valid and materially faster for the targeted
tagless/coordinates specialization, but that local result does not generalize
across the template/sink specializations produced by `emitDenseNodes`. As with
A4a and A3b, smaller generated code and fewer retired instructions in one
specialization are insufficient grounds for adoption without broad runtime
evidence.

The rejected source patch is preserved outside the repository as
`/tmp/d-osm-a5a-rejected.patch` with SHA-256
`dc59508675a8f69f5f4c7ec4d9a800a4d9380fa96e05a127511ca9dc84625d7d`.
Any future countdown-based optimization would require a separately justified
semantic specialization boundary; sink-specific tuning solely to improve a
benchmark instantiation would not establish a suitable library design.

### A6a: offsetless packed Dense column cursor

After A5a was rejected, the next experiment returned to the remaining
per-value work in the validated Dense scalar columns. `DenseColumnCursor`
already used the failure-only `sint64` reader introduced by A3a-2i, so
successful values no longer materialized a `WireStatus`. The underlying
`WireCursor`, however, still advanced three pieces of state for every decoded
byte: remaining length, data pointer, and running byte offset.

The benchmark workload stores each Dense ID, latitude, and longitude column as
one long packed length-delimited occurrence. Static inspection of the
production `tagless/coordinates` specialization confirmed that LDC retained
the running offset update in the successful packed decode path for all three
columns.

A6a therefore tested a private Dense-only representation:

- `_group` and `_dense` remained ordinary `WireCursor` instances because they
  still parse protobuf structure and require normal cursor-offset semantics;
- `_packed` became a borrowed `const(ubyte)[]`;
- a private failure-only packed `sint64` reader advanced only the slice;
- the exact value-start offset was reconstructed only for the failure path;
- public `WireCursor`, public wire-decoder behavior, legal unpacked Dense
  representation, and packed/unpacked concatenation semantics were unchanged.

The new reader was checked against the established failure-only cursor reader
for one-byte and multi-byte values, legal non-minimal encodings, truncation,
overflow, consumed-byte count, and exact non-zero failure offsets. Both LDC and
DMD passed the complete unit-test suite (24 modules).

For the `tagless/coordinates` dispatcher, A6a produced the intended generated
code. The third running cursor-state update disappeared from the successful
one-byte path. The whole specialization also became substantially smaller:

| Metric | Baseline | A6a | Change |
| --- | ---: | ---: | ---: |
| dispatcher size | 15,673 bytes | 14,864 bytes | -809 bytes |
| static instructions | 3,067 | 2,966 | -101 |
| `mov` family | 1,233 | 1,177 | -56 |
| `lea` | 494 | 432 | -62 |
| calls | 79 | 73 | -6 |

A controlled fixed-binary A-B-B-A run on `tagless/coordinates` showed a strong
and consistent local improvement:

| Comparison | A6a vs baseline |
| --- | ---: |
| mean p50 | -5.876% ns/node |
| B1 / A1 | -5.997% |
| B2 / A2 | -5.756% |
| throughput from mean p50 | +6.242% |

All four runs produced identical checksums.

A separate fixed-binary hardware-counter A-B-B-A run independently supported
the same local mechanism:

| Counter | Baseline mean | A6a mean | Change |
| --- | ---: | ---: | ---: |
| cycles | 5,971,719,410.0 | 5,622,743,184.0 | -5.844% |
| instructions | 24,108,370,017.5 | 22,892,739,751.5 | -5.042% |
| branches | 1,659,038,220.0 | 1,659,032,647.0 | ~0.000% |
| branch misses | 22,128.5 | 23,986.5 | +8.396% |
| IPC | 4.0371 | 4.0715 | +0.851% |

The branch-miss increase is large only as a relative percentage. The absolute
counts remain about 22-24 thousand misses against roughly 1.66 billion retired
branches and are not used to explain the result. Both counter pairs reduced
cycles by essentially the same amount (-5.841% and -5.847%).

The complete twelve-combination timing matrix did **not** generalize the local
win:

| Profile | Path | Mean p50 change | B1 / A1 | B2 / A2 | Direction |
| --- | --- | ---: | ---: | ---: | --- |
| tagless | coordinates | -6.164% | -6.428% | -5.899% | win |
| tagless | tag IDs | -6.114% | -6.312% | -5.916% | win |
| tagless | tag bytes | -6.018% | -6.154% | -5.881% | win |
| typical | coordinates | -0.959% | -1.096% | -0.821% | win |
| typical | tag IDs | +0.876% | +0.784% | +0.969% | loss |
| typical | tag bytes | +0.851% | +0.822% | +0.879% | loss |
| rich | coordinates | -0.448% | -0.458% | -0.439% | win |
| rich | tag IDs | +1.744% | +1.738% | +1.749% | loss |
| rich | tag bytes | +1.414% | +1.526% | +1.301% | loss |
| mixed | coordinates | -0.404% | -0.168% | -0.641% | win |
| mixed | tag IDs | +1.228% | +1.670% | +0.788% | loss |
| mixed | tag bytes | +1.145% | +1.542% | +0.748% | loss |

Checksums matched in all twelve combinations. The result was six wins, six
losses, and no mixed-direction pairs. The median combination delta was
**+0.223% ns/node**. Every real tag-consuming sink in a workload containing
tags regressed consistently, while the three coordinate-only paths and all
three tagless paths improved.

Because A5a had demonstrated that source-level DenseNodes changes can interact
strongly with frontend placement, the largest A6a loss (`rich/tag-ids`) was
examined with fixed-binary hardware counters before interpreting the timing
matrix. That run confirmed a genuine execution-cost regression rather than a
simple timing-only anomaly:

| Counter | Baseline mean | A6a mean | Change |
| --- | ---: | ---: | ---: |
| elapsed p50 | 357.778 ns/node | 364.700 ns/node | +1.935% |
| cycles | 21,187,432,679.5 | 21,570,339,512.5 | +1.807% |
| instructions | 65,612,644,787.0 | 65,835,384,793.0 | +0.339% |
| branches | 9,266,031,696.0 | 9,266,019,335.5 | ~0.000% |
| branch misses | 236,257.0 | 232,806.5 | -1.460% |
| IPC | 3.0968 | 3.0521 | -1.442% |

Both cycle pairs regressed (+1.842% and +1.773%). A6a therefore executed
slightly **more**, not less, retired work in this tagged specialization while
also losing IPC. This differs materially from the A5a placement pathology,
where the problematic specialization could execute fewer instructions but
suffer a much larger frontend-cycle penalty.

Static inspection likewise did not show a simple whole-function code-size
regression. For the `HasTags=true, HasInfo=false, TagIdSink` dispatcher A6a
actually reduced:

| Metric | Baseline | A6a | Change |
| --- | ---: | ---: | ---: |
| dispatcher size | 23,762 bytes | 22,412 bytes | -1,350 bytes |
| static instructions | 4,405 | 4,182 | -223 |
| `mov` family | 1,876 | 1,741 | -135 |
| `lea` | 707 | 634 | -73 |
| calls | 126 | 113 | -13 |
| stack references | 1,598 | 1,479 | -119 |

The stack frame nevertheless grew from `0x778` to `0x788` bytes, and normalized
assembly changed broadly because the cursor representation altered register
and stack allocation throughout the large tagged dispatcher. The measurements
do not establish one unique compiler mechanism for the regression; they do
show that smaller static code is insufficient evidence that the dynamic tagged
path became cheaper.

A6a is therefore **REJECTED as a general performance change**. Its central
micro-optimization is real and valuable in the minimal packed-coordinate path,
but the resulting cursor representation is not robust across the tagged
template/sink specializations used by the same production decoder.

#### A6b: derive packed length instead of storing it

A6b tested one narrowly motivated rework before abandoning this representation.
The hypothesis was that A6a's persistent `_packedLength` member increased live
cursor state and caused the tagged register-allocation regression. A6b removed
that member and derived the original packed length at the call site from the
existing Dense cursor and packed-base state.

This hypothesis was rejected **before runtime benchmarking**. Correctness
remained intact under both LDC and DMD, but the generated code moved in the
wrong direction:

| Dispatcher | Metric | A6a | A6b |
| --- | --- | ---: | ---: |
| tagless/coordinates | size | 14,864 | 14,994 bytes |
| tagless/coordinates | static instructions | 2,966 | 2,996 |
| tagless/coordinates | stack frame | `0x388` | `0x388` |
| tagged/tag IDs | size | 22,412 | 22,619 bytes |
| tagged/tag IDs | static instructions | 4,182 | 4,227 |
| tagged/tag IDs | stack references | 1,479 | 1,488 |
| tagged/tag IDs | stack frame | `0x788` | `0x788` |

Thus removing the persistent length neither restored the baseline tagged stack
frame nor reduced the A6a register/stack disturbance. Instead it added static
work to both inspected specializations while retaining the offsetless packed
decode.

A6b is therefore **NOT PURSUED**. The specific hypothesis that
`_packedLength` was the dominant cause of the tagged regression was falsified
by code generation before a benchmark was justified.

The broader idea of a private Dense packed-scalar representation remains a
possible **REWORK** direction, but any future attempt must avoid merely trading
one piece of cursor state for another. It should establish, before broad
benchmarking, that its successful packed path remains compact across both
tagless and `HasTags=true` specializations and that precise wire-error offsets
remain reconstructible without perturbing the common tagged code path.

The experimental artifacts were retained outside the repository. The principal
directories are:

```text
/tmp/d-osm-a6a-offsetless-packed-20260915-233126
/tmp/d-osm-a6a-targeted-abba-20260915-233831
/tmp/d-osm-a6a-counter-abba-20260915-234430
/tmp/d-osm-a6a-full-matrix-abba-20260915-235100
/tmp/d-osm-a6a-rich-tagids-counter-abba-20260916-001325
/tmp/d-osm-a6a-tagids-static
/tmp/d-osm-a6b-derived-packed-length-20260916-100353
/tmp/d-osm-a6-rejected-artifacts-20260916-100811
```

The preserved A6b rejection patch has SHA-256:

```text
c39add198a56d16d2f1d8e8f0a84ce5997ba708f3e6a90c67d1e70be1e016495
```

A6a source state is also retained as
`/tmp/d-osm-a6b-derived-packed-length-20260916-100353/a6a-before-rework.patch`.

### A7: validated canonical single-packed Dense coordinate fast path

A7 investigated whether the common canonical DenseNodes representation could
bypass the general `DenseColumnCursor` machinery after semantic validation.

The target representation was deliberately narrow:

- exactly one `DenseNodes` occurrence in the `PrimitiveGroup`;
- exactly one packed length-delimited occurrence of each Dense coordinate
  column (`id`, `lat`, and `lon`);
- no repeated, unpacked, or interleaved coordinate representation;
- all ordinary legal protobuf representations remained supported by the
  existing generic decoder as fallback.

The intended optimization was not to weaken validation. Structural and
semantic validation still established node counts, cumulative delta safety,
DenseInfo validity, and Dense tag validity before emission. The experiment
instead asked whether a validated canonical representation could expose the
three packed payloads directly and thereby remove repeated structural cursor
work from the emission loop.

#### A7a: general canonical dispatch

The first implementation extended `DenseNodesLayout` with canonical packed
offset/length metadata discovered during `PrimitiveGroup` layout decoding. A
specialized emitter then constructed three direct packed cursors from those
validated spans.

The implementation passed the complete LDC and DMD unit-test suite (24
modules). On the targeted tagless/coordinates path it produced a local
improvement of approximately **-3.42% ns/node**.

The complete twelve-combination matrix did not support general adoption:

- tagless workloads improved;
- several tagged specializations regressed;
- the matrix classified as **3 wins, 5 losses, and 4 mixed**;
- the median combination delta was **+0.493% ns/node**.

A7a was therefore **REJECTED as a general dispatch strategy**. The canonical
emitter itself was promising, but routing all DenseNodes specializations
through the additional layout state perturbed unrelated tagged code paths.

#### A7b: restrict canonical dispatch to tagless/no-info DenseNodes

A7b retained the canonical metadata discovered during layout decoding but
restricted the specialized emitter to the semantic case where both tags and
DenseInfo were absent. Tagged or info-bearing workloads remained on the
existing generic decoder.

Both LDC and DMD again passed all 24 test modules.

An emission-only twelve-combination matrix showed the intended isolation:

| Classification | Count |
| --- | ---: |
| win | 3 |
| loss | 0 |
| mixed | 9 |

All three tagless sink instantiations improved consistently:

| Path | A7b change |
| --- | ---: |
| coordinates | -3.536% |
| tag IDs | -3.558% |
| tag bytes | -3.562% |

The generic tagged dispatchers were normalized and compared across baseline
and A7b; all twelve inspected generic specializations were identical. The
canonical `HasTags=false, HasInfo=false` dispatcher was approximately 6.5 KiB
per benchmark sink instantiation, increasing benchmark `.text` by roughly
20.4 KiB across the three sinks.

Hardware counters on tagless/coordinates supported the local mechanism:

| Counter | A7b change |
| --- | ---: |
| cycles | -3.740% |
| instructions | -1.692% |
| branches | -12.236% |
| branch misses | approximately -14% |
| IPC | +2.127% |

The branch-miss count was very small in absolute terms and is retained only as
diagnostic evidence.

However, the benchmark above measured emission after a predecoded
`PrimitiveGroupLayout`. The canonical spans were not free: A7b added discovery
work to layout decoding for every relevant Dense group.

A temporary end-to-end benchmark therefore moved
`decodePrimitiveGroupLayout()` inside the timed region before the existing
production `decodeDenseNodes()` preflight and emission. Its benchmark source
SHA-256 was:

```text
79cbda9fb39e7cf0c7d91fa64a56b99fc93f7c176867421933411da1be422f6d
```

In that combined layout-plus-emission matrix, A7b produced **1 win, 0 losses,
and 11 mixed** combinations with a median delta of **-0.095%**. The tagless
paths that had improved by about 3.5% in emission-only measurement became
essentially neutral end to end.

A dedicated layout-only benchmark explained the disappearance. Canonical
metadata discovery made layout decoding approximately **2.00% slower**.

A7b therefore demonstrated that the canonical emitter removes real dynamic
work, but also that discovering and persisting its metadata during ordinary
layout decoding consumes almost the entire end-to-end benefit.

#### A7c: separate canonical structure discovery from Dense validation

A7c tested whether the layout cost came from perturbing the already large
`scanDenseNodes()` validator rather than from the canonical discovery itself.

`scanDenseNodes()` was restored byte-for-byte to the production source.
Canonical structure discovery moved into a separate helper that scanned only
protobuf field structure:

- first DenseNodes occurrence only;
- coordinate fields `1`, `8`, and `9`;
- each required exactly once and length-delimited;
- non-coordinate fields were skipped;
- exact payload offsets and lengths were recorded;
- repeated DenseNodes disabled the canonical flag.

The production and A7c `scanDenseNodes()` sources had identical SHA-256:

```text
92a53c60dbcc64a1441cf6eec1151f29e9a00d3be576b1f105def38d48ec3982
```

All 24 LDC and DMD test modules passed.

The normal layout-only benchmark still showed a stable regression:

| Variant | Layout cost |
| --- | ---: |
| baseline | 26.536 ns/node-equivalent workload cost |
| A7c | 26.8705 |
| change | +1.261% |

Hardware counters did **not** show additional retired work:

| Counter | A7c change |
| --- | ---: |
| cycles | +1.120% |
| instructions | -0.001% |
| branches | -0.004% |
| IPC | -1.109% |

This pattern suggested another code-placement/frontend effect rather than an
algorithmic cost large enough to explain the measured regression.

Because A5a had already established strong sensitivity on this Intel CPU to
32-byte branch placement, A7c was rebuilt with LLVM's explicit mitigation:

```text
--x86-branches-within-32B-boundaries
```

Under that controlled build, the layout-only result collapsed from **+1.261%**
to approximately **-0.114%**, i.e. measurement-neutral. This was strong
evidence that the apparent A7c layout regression was dominated by generated
code placement rather than by the structure scanner itself.

The normal unmitigated combined layout-plus-emission matrix was correspondingly
ambiguous: **1 win, 1 loss, and 10 mixed**, with a median delta of **+0.242%**.
The tagless paths were effectively neutral.

A repeated tagged hardware-counter run also showed essentially unchanged
retired work and frequency behavior, reinforcing that unrelated tagged timing
movement was a frontend/layout artifact rather than execution of the canonical
fast path.

#### A7d: source-level helper reordering

A7d tested the narrow hypothesis that inserting the canonical discovery helper
between existing hot `primitive_group.d` functions had changed their linker or
compiler placement.

The helper was moved in source after `validateDenseInfo()`. Its own source was
identical before and after the move, and all tests passed.

LDC nevertheless emitted every relevant function at exactly the same address,
size, and 64-byte phase as A7c:

- `scanDenseNodes`;
- canonical discovery helper;
- `acceptDenseDelta`;
- `scanPackedSInt64`;
- `validateDenseInfo`.

Normalized generated code for all relevant functions was likewise identical.

A7d is therefore **NOT PURSUED**. Source order did not control the relevant
generated-function placement and could not address the frontend artifact.

#### A7e: discover canonical packed spans only after tagless/no-info dispatch

A7e removed canonical metadata from `PrimitiveGroupLayout` entirely.

`primitive_group.d` was restored exactly to production. Only after the normal
production sequence had completed

- coordinate preflight;
- DenseInfo validation;
- Dense tag validation; and
- semantic dispatch had established `HasTags=false` and `HasInfo=false`

did `dense_nodes.d` perform a local one-pass structure scan for the canonical
three packed coordinate spans.

The descriptor was stack-local and used six `size_t` offset/length values.
Failure to prove the exact canonical representation simply selected the
existing generic decoder. No public wire semantics or legal protobuf fallback
representation changed.

This design had an important architectural advantage over A7b/A7c: tagged and
DenseInfo-bearing inputs did not execute the canonical discovery scanner, and
`PrimitiveGroupLayout` returned to its production representation.

The A7e production patch passed all 24 test modules under both LDC and DMD.

Static placement inspection nevertheless showed that adding the specialized
DenseNodes code shifted the complete `primitive_group` validator block in the
linked benchmark binary by **+20,832 bytes**, changing every inspected
function's `mod 64` phase by 32 bytes even though function sizes were
unchanged.

After normalizing direct targets and RIP-relative linked addresses, the
generated instruction sequences for all five inspected hot functions were
identical between baseline and A7e:

- `decodePrimitiveGroupLayout`;
- `scanDenseNodes`;
- `acceptDenseDelta`;
- `scanPackedSInt64`;
- `validateDenseInfo`.

This reproduced the same kind of placement confound diagnosed during A5a.

Both binaries were therefore rebuilt with LLVM's 32-byte branch-boundary
mitigation. Under that build all five validator functions had matching
`mod 32` and `mod 64` phases between baseline and A7e, while retaining
identical sizes. The controlled JCC build was then used for the decisive
end-to-end matrix.

The benchmark used:

```text
CPU:             5
nodes:           200000
iterations:      20 per sample
samples:         30
warmup:          10
ordering:        A-B-B-A
timed region:    PrimitiveGroup layout decode
                 + production decodeDenseNodes preflight
                 + emission
                 + selected sink work
```

The three target tagless paths all regressed reproducibly:

| Profile | Path | Mean p50 change | B1 / A1 | B2 / A2 |
| --- | --- | ---: | ---: | ---: |
| tagless | coordinates | +0.951% | +0.880% | +1.021% |
| tagless | tag IDs | +1.030% | +1.080% | +0.980% |
| tagless | tag bytes | +1.067% | +1.051% | +1.084% |

These are the only paths that execute A7e's late canonical discovery and
specialized emitter. Their agreement across three independent sink
instantiations is therefore the primary optimization result.

Several non-target tagged combinations showed isolated process-level
variation. In particular, `typical/tag-ids` and `mixed/tag-ids` contained
single-run outliers with opposite paired direction and are not attributed to
the A7e mechanism. The whole twelve-combination median was **+0.300%**, but the
decision is based on the directly affected tagless paths rather than that
mixed matrix aggregate.

A separate four-round fixed-binary A-B-B-A hardware-counter experiment on
tagless/coordinates confirmed the regression and explained its character:

| Counter | A7e vs baseline |
| --- | ---: |
| cycles | +1.118% |
| reference cycles | +1.118% |
| instructions | +1.301% |
| branches | -1.913% |
| branch misses | -4.041% |
| IPC | +0.180% |
| cycles / reference cycles | +0.000% |

Thus A7e successfully removes branches, but it retires approximately **1.3%
more instructions overall**. Frequency behavior is identical and IPC slightly
improves, while total cycles still increase by approximately **1.1%**.

This is materially different from the earlier A5a frontend-placement failure:
after controlling 32-byte branch placement, A7e remains slower because the
late canonical structure scan adds more dynamic work than the specialized
emitter saves.

A7e is therefore **REJECTED**.

The broader result of A7 is more informative than the final rejection alone:

1. Direct canonical packed emission is measurably cheaper once exact spans are
   already known.
2. Persisting those spans during general layout decoding is not free enough to
   justify the added metadata and code footprint.
3. Discovering them lazily only for tagless/no-info input avoids cross-path
   semantic pollution, but still performs net additional work.
4. Large template specializations can shift unrelated hot code sufficiently
   to invalidate ordinary timing comparisons on the tested Intel CPU/microcode
   environment; controlled LLVM branch-boundary builds are required when that
   signature appears.
5. A future canonical fast path would need span information to become available
   essentially for free from work that must already occur for another reason,
   rather than adding another protobuf structure scan solely to accelerate
   emission.

A7 is therefore classified **REWORK**. A7a, A7b, A7c, and A7e were not retained
as production implementations, and A7d was not pursued. The useful remaining design
question is whether a later parser architecture can expose canonical packed
spans as a natural by-product of required validation without increasing the
general layout representation or rescanning the serialized DenseNodes
message.

The principal retained diagnostic artifacts are:

```text
/tmp/d-osm-a7b-e2e-baseline
/tmp/d-osm-a7b-full-matrix-20260916-132749
/tmp/d-osm-a7b-counters-root-20260916-135121
/tmp/d-osm-a7b-layout-plus-emission-matrix-20260916-142018
/tmp/d-osm-a7b-layout-only-20260916-145845
/tmp/d-osm-a7c-layout-only-20260916-193923
/tmp/d-osm-a7c-layout-jcc-20260916-200534
/tmp/d-osm-a7c-combined-matrix-20260916-202724
/tmp/d-osm-a7c-typical-tagbytes-counters-20260916-215752
/tmp/d-osm-a7d-placement-20260916-222346
/tmp/d-osm-a7e-placement-20260916-232425
/tmp/d-osm-a7e-validator-codegen-20260916-232708
/tmp/d-osm-a7e-validator-codegen-ripnorm-20260916-232812
/tmp/d-osm-a7e-jcc-build-20260916-232921
/tmp/d-osm-a7e-jcc-matrix-20260916-235809
/tmp/d-osm-a7e-jcc-tagless-counters-20260917-002642
/tmp/d-osm-a7e-rejected-artifacts-20260917-003728
```

The preserved A7e rejection patch is:

```text
/tmp/d-osm-a7e-rejected-artifacts-20260917-003728/a7e-rejected.patch
```

with SHA-256:

```text
9b8bbd5d6d74fa8ab177b387463e3db3925cf9d65d18fb0acd2206e1ba995c59
```

### A8: reuse the validated sole DenseNodes payload for tagless coordinate cursors

A7 established that a specialized Dense coordinate emitter can be cheaper when
exact serialized spans are already known, but that performing another protobuf
structure scan solely to discover those spans is not profitable.

A8 therefore started from a narrower observation: `decodePrimitiveGroupLayout()`
already has to decode the outer `PrimitiveGroup` and already encounters every
field-2 `DenseNodes` length-delimited payload before `scanDenseNodes()` validates
its contents. The existing `DenseColumnCursor`, however, independently rescanned
the complete `PrimitiveGroup` to rediscover that same `DenseNodes` payload before
looking for coordinate field `1`, `8`, or `9`.

The A8 hypothesis was therefore:

> retain the already-known sole `DenseNodes` payload location as a by-product of
> mandatory layout validation and let tagless coordinate cursors start directly
> inside that payload.

The experiment deliberately did **not** add a second structure scan, did not
cache individual coordinate spans, and did not narrow the legal protobuf
representations accepted by the generic decoder.

#### A8a: first cache representation perturbed the validator

The first implementation attempted to reclaim the two existing
`hasLatRange` / `hasLonRange` bytes and derive range presence from coordinate
counts.

Although semantically valid, that changed generated code in
`acceptDenseDelta()`: the former boolean checks became wider count-based tests
and altered register allocation.

A cache-write-disabled control still regressed by approximately **+0.404%**,
while restoring the independent booleans restored the previous validator
code generation.

A8a was therefore **REJECTED**. Metadata reuse was still worth investigating,
but not by perturbing the established Dense validation representation.

#### A8b: six-byte tail-padding cache, consumed by all Dense paths

The revised representation preserved both range booleans and occupied only the
six bytes of existing 64-bit tail padding in `DenseNodesLayout`:

```text
offset 112: bool hasLatRange
offset 113: bool hasLonRange
offset 114: ubyte[3] DenseNodes payload offset
offset 117: ubyte[3] DenseNodes payload length
sizeof(DenseNodesLayout) = 120
alignof(DenseNodesLayout) = 8
```

The payload offset and length are stored as little-endian 24-bit integers.
Values larger than `0xFF_FFFF` are intentionally not cached and retain the
generic path. This preserves the full parser input domain even though the
optimization cache itself represents only payloads below approximately 16 MiB.

A zero offset is the no-cache sentinel. A valid field-2 payload cannot begin at
offset zero because its protobuf key and length prefix necessarily precede the
payload.

Repeated `DenseNodes` occurrences are also deliberately uncached because
protobuf message fields merge across occurrences; the existing generic cursor
remains the semantic fallback.

Static inspection showed:

- `DenseNodesLayout.sizeof == 120`;
- `PrimitiveGroupLayout.sizeof == 168`;
- `scanDenseNodes()` unchanged;
- `acceptDenseDelta()` unchanged.

Decoder-only scaling showed a nearly fixed saving of roughly **80–95 ns per
decoded group** through the small and medium group sizes.

The general A8b consumer was nevertheless rejected after a targeted
`mixed/tag-bytes` hardware-counter run showed a real tagged-path regression:

```text
elapsed       +1.354%
cycles        +0.934%
instructions  -0.093%
branches      ~0%
IPC           -1.017%
```

Both elapsed-time pairs and cycle pairs regressed. A8b therefore demonstrated
that the outer-payload cache itself was useful, but consuming it in every
semantic specialization was too broad.

#### A8c: consume the cache only in compile-time tagless specializations

A8c retained the cache but restricted the new cursor constructor to
`HasTags == false`:

```d
static if (HasTags)
{
    DenseColumnCursor ids  = DenseColumnCursor(group.raw, 1);
    DenseColumnCursor lats = DenseColumnCursor(group.raw, 8);
    DenseColumnCursor lons = DenseColumnCursor(group.raw, 9);
}
else
{
    DenseColumnCursor ids  = DenseColumnCursor(group, 1);
    DenseColumnCursor lats = DenseColumnCursor(group, 8);
    DenseColumnCursor lons = DenseColumnCursor(group, 9);
}
```

There is therefore no runtime branch in the per-node emission loop.

Under the controlled LLVM JCC build, all six inspected `HasTags=true`
dispatchers had the same symbol sizes as baseline, and normalized tagged
dispatcher disassembly was identical.

A targeted tagged hardware-counter confirmation on `mixed/tag-bytes` then
showed that the A8b regression had disappeared:

```text
elapsed       -0.028%
cycles        -0.414%
instructions  +0.000%
branches      -0.000%
IPC           +0.415%
```

The tagless decoder-only scaling continued to show the expected fixed one-time
saving.

A recovered end-to-end benchmark was then used so that each timed decode
included:

```text
PrimitiveGroup layout decode
+ production decodeDenseNodes preflight
+ emission
+ selected sink work
```

Under the JCC-controlled build, tagless end-to-end scaling showed approximately:

| Nodes | Typical saving |
| ---: | ---: |
| 1 | 76–79 ns/group |
| 4 | 76–88 ns/group |
| 16 | 83–96 ns/group |
| 64 | 80–91 ns/group |
| 256 | 87–104 ns/group |
| 1024+ | amortized toward measurement-neutral |

A 200,000-node hardware-counter run was effectively neutral:

```text
elapsed       +0.010%
cycles        -0.134%
ref cycles    -0.134%
instructions  -0.001%
branches      -0.001%
IPC           +0.131%
```

A mirrored 200,000-node run likewise produced an overall pair median of
approximately **-0.089%**.

A8c still recorded the payload cache during layout decoding for groups that
would later dispatch to tagged emitters. A dedicated tagged end-to-end matrix
was noisy but had a median cell delta of **+0.135%**, motivating one final
narrowing of cache production.

That matrix also exposed an important semantic distinction: the benchmark's
`mixed/1` case contains an explicit `keys_vals = [0]` node delimiter but zero
actual tags. `validateDenseTags()` therefore dispatches it with `HasTags=false`,
even though the serialized `keys_vals` field is non-empty.

This meant that `keysValsCount > 0` cannot be used as a semantic synonym for
"has tags".

#### A8d/A8e: conservatively produce the cache only for implicit-all-tagless input

The final design avoids reproducing Dense tag semantics inside
`scanDenseNodes()` or `decodePrimitiveGroupLayout()`.

The payload cache is produced only when all of the following are already known
from mandatory layout work:

```text
DenseNodes occurrences == 1
keysValsCount == 0
payload offset <= 0xFF_FFFF
payload length <= 0xFF_FFFF
```

An entirely absent logical `keys_vals` stream is the format-defined compact
representation for all-tagless Dense nodes and is therefore a safe conservative
proxy for the profitable consumer.

A non-empty `keys_vals` stream containing only zero delimiters is legal and may
later validate to zero actual tags, but it intentionally remains uncached. This
avoids duplicating tag-value semantics merely to widen the optimization.

A8d initially cleared the six-byte cache even on the first tagged occurrence.
Because a freshly initialized layout already contains zero there, A8e removed
those redundant stores. Only a later `DenseNodes` occurrence must clear a cache
possibly established by the first occurrence.

Unit coverage verifies:

- exact 24-bit set/read/clear behavior;
- the canonical sole packed payload cache (`offset=2`, `length=0x14`);
- explicit zero-delimiter-only `keys_vals` remains uncached;
- repeated legal `DenseNodes` occurrences clear/disable the cache;
- the 64-bit structure size and member offsets remain fixed.

All **24 test modules passed under both LDC and DMD**, and `git diff --check`
remained clean.

#### A8e controlled end-to-end result

The final A8e JCC-controlled candidate was compared against the production
baseline using A-B-B-A ordering.

Tagless scaling retained the intended fixed-cost improvement:

| Nodes | coordinates | tag IDs | tag bytes |
| ---: | ---: | ---: | ---: |
| 1 | -11.878% | -11.929% | -11.647% |
| 4 | -11.805% | -11.367% | -11.166% |
| 16 | -7.256% | -7.178% | -6.788% |
| 64 | -2.809% | -3.241% | -2.942% |
| 256 | -0.741% | -0.962% | -0.806% |
| 1024 | +0.013% | -0.016% | -0.071% |

Across the small and medium groups, the absolute saving remained approximately
**75–98 ns per group**, matching the hypothesis that A8 removes one redundant
outer `PrimitiveGroup` discovery scan rather than changing per-node complexity.

The apparent 200,000-node regression from the long scaling sequence was tested
again with mirrored A-B-B-A plus B-A-A-B ordering:

| Path | Mean change | Median paired change |
| --- | ---: | ---: |
| coordinates | -0.034% | -0.021% |
| tag IDs | -0.016% | -0.014% |
| tag bytes | +0.048% | +0.021% |

The median across all twelve mirrored pair comparisons was **+0.003%**, with no
checksum failures. The very-large-group result is therefore measurement-neutral,
as expected when the fixed scan saving is fully amortized.

The final tagged end-to-end matrix was noisier and showed no consistent scaling
signature. Its median cell delta was **+0.297%**, but only two of seventeen cells
regressed in both paired comparisons; one of those had a first paired delta of
only **+0.007%**. Positive and negative group-time deltas varied widely rather
than behaving like a fixed layout tax.

Static inspection provides the stronger isolation evidence for those non-target
paths. Relative to the production baseline:

```text
scanDenseNodes                   3399 -> 3399 bytes
acceptDenseDelta                  484 ->  484 bytes
CoordinateSink decodeDenseNodes   967 ->  967 bytes
TagIdSink decodeDenseNodes        967 ->  967 bytes
TagByteSink decodeDenseNodes      967 ->  967 bytes
decodePrimitiveGroupLayout        925 ->  993 bytes
new layout-based cursor ctor        - ->  174 bytes
```

After normalizing branch targets and RIP-relative placement, generated
instruction sequences were **identical** between baseline and A8e for:

- `scanDenseNodes`;
- `acceptDenseDelta`;
- `decodeDenseNodes<CoordinateSink>`;
- `decodeDenseNodes<TagIdSink>`;
- `decodeDenseNodes<TagByteSink>`.

The optimization is therefore localized to layout discovery and the new
layout-aware cursor construction. It does not perturb the established Dense
validation scanner or per-node emitter code generation.

#### A8 classification

A8e is **KEEP**.

It realizes the useful architectural result left by A7: span information
becomes available as a by-product of work the parser already has to perform,
rather than through another protobuf scan.

The retained production mechanism is intentionally conservative:

1. preserve the existing Dense validator representation and code generation;
2. use only six bytes of existing 64-bit structure padding;
3. cache only the sole implicit-all-tagless `DenseNodes` payload;
4. retain generic parsing for tagged, explicit-delimiter-only, repeated, and
   unrepresentable-large payloads;
5. consume the cache only in compile-time `HasTags=false` specializations;
6. remove one redundant outer `PrimitiveGroup` scan without changing legal wire
   semantics.

Principal A8 artifacts:

```text
/tmp/d-osm-a8b-mixed-tagbytes-counter-abba-20260917-191727
/tmp/d-osm-a8c-tagged-static-20260917-203414
/tmp/d-osm-a8c-mixed-tagbytes-counter-abba-20260917-203742
/tmp/d-osm-a8c-tagless-scaling-abba-20260917-204446
/tmp/d-osm-a8c-e2e-jcc-build-20260918-094853
/tmp/d-osm-a8c-e2e-tagless-scaling-abba-20260918-102001
/tmp/d-osm-a8c-e2e-200k-counter-abba-20260918-103747
/tmp/d-osm-a8c-e2e-200k-mirrored-20260918-104120
/tmp/d-osm-a8c-e2e-tagged-layout-tax-20260918-130836
/tmp/d-osm-a8d-e2e-tagged-layout-tax-20260918-135923
/tmp/d-osm-a8e-e2e-jcc-build-20260918-142625
/tmp/d-osm-a8e-e2e-tagged-layout-tax-20260918-142820
/tmp/d-osm-a8e-e2e-tagless-scaling-abba-20260918-144823
/tmp/d-osm-a8e-e2e-200k-mirrored-20260918-145741
/tmp/d-osm-a8e-hot-symbols-20260918-150330
/tmp/d-osm-a8e-hot-disasm-20260918-150924
```

## A9a: remove duplicate DenseNodes column-length guard

A9a revisited fixed decode-time work after the retained A8e payload-cache
optimization. The candidate removed the second ID/latitude/longitude column
length comparison from `decodeDenseNodes()`.

The semantic premise is stronger than a heuristic optimization.
`decodeDenseNodes()` explicitly requires its `PrimitiveGroupLayout` argument to
have been produced by `decodePrimitiveGroupLayout()`. That layout decoder
already rejects DenseNodes when the merged ID, latitude, and longitude counts
differ. Fabricating such a layout, or mutating aliased backing bytes after
validation, violates the existing validated-layout precondition used by the
earlier accepted DenseNodes arithmetic optimizations.

The experiment changed only this redundant guard. Dense coordinate preflight,
DenseInfo validation, dense-tag validation, dispatch, cursor behavior, and
emission remained unchanged.

Both DMD 2.111.0 and LDC 1.41.0 passed all 24 unit-test modules.

For performance measurement, baseline and candidate were built with LDC 1.41.0
/ LLVM 19.1.7 and LLVM's Intel JCC 32-byte-boundary mitigation:

```text
--x86-branches-within-32B-boundaries
```

The benchmark ran pinned to logical CPU 5 with SMT sibling CPU 11 offline and
turbo disabled. Fixed binaries were compared in A-B-B-A order on the
`tagless/coordinates` path. All checksums matched.

| Nodes/group | Mean candidate p50 change | Approx. decode-time delta |
| ---: | ---: | ---: |
| 1 | -0.051% | -0.205 ns/decode |
| 4 | -0.643% | -2.736 ns/decode |
| 16 | -0.069% | -0.384 ns/decode |
| 64 | -0.155% | -1.728 ns/decode |

The small differences did not form the approximately constant absolute saving
expected from removal of fixed per-decode work. The 4-node result was also
visibly affected by baseline process drift. A9a is therefore classified as
**runtime-neutral**, not as a demonstrated throughput optimization.

Static code generation did change materially. Each of the three benchmark
`decodeDenseNodes` sink instantiations shrank from 967 bytes to 862 bytes,
a reduction of 105 bytes each. The complete executable `.text` section shrank
by 320 bytes. Whole-binary disassembly counts changed as follows:

```text
instructions         193147 -> 193068
conditional jumps     20556 -> 20547
unconditional jumps    5429 -> 5426
calls                  8831 -> 8828
```

All `dispatchDenseNodes` specialization sizes remained unchanged; their
addresses merely shifted with the smaller preceding code.

A9a is therefore **KEEP** as validated-layout deduplication and static
code-size cleanup, with no claimed runtime speedup. The removed failure path
does not protect a supported caller state: an unequal Dense ID/latitude/
longitude layout has already been rejected by the required
`decodePrimitiveGroupLayout()` stage.

## A10a: skip redundant DenseTags String-ID validation during prevalidated node partitioning

A10a revisited the tagged DenseNodes hot path after A9a.

The complete `validateDenseTags()` preflight already proves, for the same
`PrimitiveGroup` and `StringTable`, that every non-zero logical `keys_vals`
entry is a valid positive signed-int32 StringTable ID and resolves within the
indexed table. Production `decodeDenseNodes()` calls this complete preflight
before selecting a tagged emitter.

Before A10a, `DenseTagNodeCursor.nextNode()` nevertheless repeated
`validateStringId()` for every non-zero `keys_vals` entry while partitioning
the already validated stream into per-node ranges. The later `DenseTagRange`
decode remained independently checked as well.

The public cursor intentionally promises defensive behavior, so simply
removing its checks would have weakened a supported API contract.

A10a therefore introduced a narrower package-internal path:

```text
public nextNode()
    -> retains defensive String-ID validation

package nextPrevalidatedNode()
    -> requires successful validateDenseTags()
    -> requires the same backing bytes to remain unchanged
    -> retains wire decoding, delimiter, pair-structure and node-count checks
    -> skips only the already-proven String-ID semantic validation
```

The common implementation uses a compile-time `ValidateStringIds` capability,
so there is no new runtime branch in the per-value partition loop.

The production `decodeDenseNodes()` emitter uses the package-internal path only
after its immediately preceding successful `validateDenseTags()` call.
`DenseTagRange.fromValidated()` and `decodeValidatedPair()` are unchanged in
A10a; actual range consumption therefore still performs the existing
per-pair validation and StringTable lookup. Removing that later redundancy is
explicitly outside A10a and requires a separate experiment.

The stale source comment describing `const` backing bytes as immutable was
also corrected. The contract is now stated precisely: the complete stream was
prevalidated and its backing must remain unchanged while the range relies on
that proof.

### Correctness validation

The A10a source delta passed:

```text
git diff --check
DMD 2.111.0: 26 modules passed unittests
LDC 1.41.0: 26 modules passed unittests
LDC 1.41.0 release build: PASS
```

### Controlled benchmark setup

Baseline source:

```text
a45894c0518461931d0ab263c14b5a60adefda82
```

Toolchain:

```text
LDC 1.41.0
DMD frontend 2.111.0
LLVM 19.1.7
target x86_64
```

Both fixed benchmark binaries were built with LLVM's Intel JCC
32-byte-boundary mitigation:

```text
--x86-branches-within-32B-boundaries
```

The controlled host state was:

```text
logical CPU:            5
SMT sibling CPU 11:     offline
intel_pstate no_turbo:  1
ordering:                A-B-B-A
```

Each benchmark phase used:

```text
nodes:       200000
iterations:  5 per sample
samples:     30
warmup:      2
profiles:    typical, rich, mixed
paths:       coordinates, tag-ids, tag-bytes
CPU:         5
```

Fixed binary identities:

```text
baseline:
4821a910a04e9e93dfa4683ef08877218aa610c1b9d77336af2a18794160f8cd

A10a candidate:
45a0d9029f2cfc2a045d50d1155ef4f0e73846e0e6a56acea5723c20aad700e8
```

All compared runs produced the expected matching checksum for a given
profile/path.

### Coordinates-only result

| Profile | Tags/node | Baseline mean p50 | A10a mean p50 | Saved | A10a vs baseline |
| --- | ---: | ---: | ---: | ---: | ---: |
| typical | 2.000 | 106.819 ns/node | 97.057 ns/node | 9.762 ns/node | -9.138% |
| rich | 8.000 | 258.803 ns/node | 226.029 ns/node | 32.774 ns/node | -12.663% |
| mixed | 1.625 | 93.241 ns/node | 85.344 ns/node | 7.897 ns/node | -8.469% |

The A phases returned to essentially the same baseline level after the two B
phases, while both candidate phases remained distinctly faster.

### Full tag-consumption result

| Path | Profile | Baseline mean p50 | A10a mean p50 | Saved | A10a vs baseline |
| --- | --- | ---: | ---: | ---: | ---: |
| tag IDs | typical | 135.627 ns/node | 127.812 ns/node | 7.815 ns/node | -5.762% |
| tag IDs | rich | 358.835 ns/node | 324.054 ns/node | 34.781 ns/node | -9.693% |
| tag IDs | mixed | 121.016 ns/node | 114.079 ns/node | 6.937 ns/node | -5.732% |
| tag bytes | typical | 147.971 ns/node | 140.153 ns/node | 7.818 ns/node | -5.283% |
| tag bytes | rich | 400.510 ns/node | 373.541 ns/node | 26.970 ns/node | -6.734% |
| tag bytes | mixed | 131.875 ns/node | 123.409 ns/node | 8.466 ns/node | -6.420% |

The optimization therefore remains beneficial when the returned
`DenseTagRange` is actually traversed and its current checked pair decoder is
executed. No measured benchmark cell regressed.

### Static code-generation localization

The fixed A10a executable became smaller:

```text
baseline .text   1,209,485 bytes
A10a .text       1,204,077 bytes
delta               -5,408 bytes
```

The relevant symbol-size changes were confined to the six benchmark
`dispatchDenseNodes` instantiations with `HasTags=true`:

```text
CoordinateSink, HasInfo=true    -2606 bytes
CoordinateSink, HasInfo=false    -640 bytes
TagIdSink,      HasInfo=true     -224 bytes
TagIdSink,      HasInfo=false    -864 bytes
TagByteSink,    HasInfo=true     -224 bytes
TagByteSink,    HasInfo=false    -864 bytes
------------------------------------------------
summed                              -5422 bytes
```

Relevant surrounding symbols were unchanged in size:

```text
decodeDenseNodes                 0x35e -> 0x35e
validateDenseTags                0xe65 -> 0xe65
DenseTagRange.fromValidated     0x1696 -> 0x1696
TagIdSink.put                   0x169d -> 0x169d
TagByteSink.put                 0x177d -> 0x177d
```

The six tagged dispatcher reductions sum to 5,422 bytes while whole
executable `.text` decreases by 5,408 bytes. The material code-generation
change is therefore localized to the expected tagged emitter specializations.

### Reproducibility material

The benchmark implementation remains in `benchmark/micro/dense_nodes.d` and
the semantic comparison reference remains in
`benchmark/reference/dense_nodes_cpp.cpp`.

The investigation used transient fixed artifacts and captured logs under:

```text
/tmp/osm-d-a10-baseline
/tmp/osm-d-a10-candidate
/tmp/osm-d-a10-abba
/tmp/osm-d-a10-tag-consumption-abba
/tmp/osm-d-a10-static
```

These `/tmp` paths are diagnostic artifacts, not repository dependencies.

### A10a classification

A10a is **KEEP**.

The retained optimization is deliberately narrow:

1. keep complete hostile-input DenseTags preflight;
2. keep public `DenseTagNodeCursor.nextNode()` defensive;
3. expose the assumption only through a package-internal prevalidated path;
4. retain wire, delimiter, pairing and node-count checks;
5. remove only StringTable-ID semantic checks already proved by preflight;
6. leave `DenseTagRange` pair decoding unchanged for A10a.

The controlled runtime result is positive across all nine measured tagged
workload/path combinations, ranging from **-5.283% to -12.663%**.

A later experiment may investigate redundant String-ID validation during
actual `DenseTagRange` pair decoding. That is a distinct experiment and is not
implied by the A10a KEEP decision.

## A10b: reuse validated DenseTagRange String IDs during pair decoding

A10b continues the validated-state deduplication introduced by A10a.

### Premise

`DenseTagRange` is construction-controlled inside `dense_tags.d`. Its stream,
table, front value, and remaining count are private, and its private
`fromValidated()` constructor is reached only through `DenseTagNodeCursor`.

There are two supported non-empty construction paths:

1. public `nextNode()`, which defensively validates every non-zero StringTable
   ID while partitioning the node segment; and
2. package-internal `nextPrevalidatedNode()`, which is used by production
   DenseNodes emission only after complete `validateDenseTags()` validation of
   the same PrimitiveGroup/StringTable pair.

Both paths therefore establish that every raw key/value ID subsequently
consumed by the produced range is a positive int32 value within the same
StringTable. The validated backing bytes are required to remain unchanged
while the range relies on this proof.

Before A10b, `DenseTagRange.fromValidated()` and later `popFront()` still
called a pair decoder that repeated `validateStringId()` for both key and
value.

### A10b scope

A10b renames that internal helper to `decodePrevalidatedPair()` and removes
only the repeated String-ID domain/range validation from the range pair
decoder.

It retains:

- `KeysValsCursor.next()` and its wire decoding;
- the construction-controlled `DenseTagRange`;
- complete hostile-input validation in `validateDenseTags()`;
- defensive String-ID validation in public `DenseTagNodeCursor.nextNode()`;
- the A10a package-internal prevalidated node-partition contract;
- both `StringTableView.get()` calls;
- `StringTableView.get()` index bounds checks; and
- `StringRef` offset/length validation against the borrowed block.

The raw values are converted to `uint` only after the range's validated-state
precondition has already proved that conversion valid.

This remains a Level-1 validated-state optimization with construction control
provided by the private range representation; no new public unchecked API or
freely fabricable capability is introduced.

### Correctness

Before performance measurement the candidate passed:

    git diff --check
    DMD 2.111.0: 26 modules passed unittests
    LDC 1.41.0: 26 modules passed unittests
    LDC 1.41.0 release build: PASS

### Fixed benchmark artifacts

A10a baseline:

    45a0d9029f2cfc2a045d50d1155ef4f0e73846e0e6a56acea5723c20aad700e8

A10b candidate:

    639f148b60b1d76287f83d79ec416649cb322dd52116d960d21fbeabbcc83438

Frozen A10b patch:

    ae18b73912971b3f876106b059abd5b9ea188a9a4f00e5b223028b4260c410db

The A10a baseline rebuilt from commit `e1b9de8` was bit-identical to the
previously measured A10a candidate, providing a direct continuation of the
A10 experiment series.

Both binaries used LDC 1.41.0 / LLVM 19.1.7, release all-at-once compilation,
and LLVM's Intel JCC 32-byte-boundary mitigation.

### Rejected first A10b timing series

The first full A-B-B-A attempt was rejected before making a KEEP/REJECT
decision because the host entered two visibly different execution states
during the matrix. In particular, `rich/coordinates` changed from roughly
450 ns/node to roughly 227 ns/node inside one A-B-B-A cell.

That series is diagnostic evidence only and is not used for the retained
performance conclusion.

A subsequent six-run baseline stability probe produced:

    min       226.030 ns/node
    median    226.353 ns/node
    max       227.919 ns/node
    max/min     0.836 %

A simultaneous `perf stat` probe reported nearly identical cycles and
ref-cycles, consistent with the controlled nominal-frequency state.

### Stable-gated full matrix

The retained full matrix used:

- logical CPU 5;
- SMT sibling CPU 11 offline;
- Intel turbo disabled;
- `performance` governor;
- scaling min/max fixed at 2.6 GHz;
- 200,000 nodes;
- 5 iterations per sample;
- 30 samples;
- 2 warmups; and
- A-B-B-A ordering.

Before every benchmark phase a short fixed A10a `rich/coordinates` sentinel
was run. Across all 36 sentinels:

    min       225.570 ns/node
    median    226.526 ns/node
    max       230.293 ns/node
    max/min     2.094 %

Core and package thermal-throttle counters both changed by zero during the
matrix.

Results:

| Path | Profile | A10a mean p50 | A10b mean p50 | Saved | A10b vs A10a |
| --- | --- | ---: | ---: | ---: | ---: |
| coordinates | typical | 97.189 ns/node | 95.534 ns/node | 1.655 ns/node | -1.703% |
| coordinates | rich | 226.406 ns/node | 224.608 ns/node | 1.798 ns/node | -0.794% |
| coordinates | mixed | 85.582 ns/node | 85.134 ns/node | 0.448 ns/node | -0.524% |
| tag IDs | typical | 127.445 ns/node | 125.645 ns/node | 1.800 ns/node | -1.412% |
| tag IDs | rich | 323.099 ns/node | 321.385 ns/node | 1.714 ns/node | -0.530% |
| tag IDs | mixed | 113.555 ns/node | 111.725 ns/node | 1.831 ns/node | -1.612% |
| tag bytes | typical | 139.712 ns/node | 138.936 ns/node | 0.776 ns/node | -0.555% |
| tag bytes | rich | 369.046 ns/node | 366.776 ns/node | 2.269 ns/node | -0.615% |
| tag bytes | mixed | 129.201 ns/node | 121.791 ns/node | 7.410 ns/node | -5.735% |

All A/B phases produced identical expected checksums for the corresponding
path/profile.

The `mixed/tag-bytes` magnitude was treated cautiously because its A10a phases
showed a bimodal baseline despite stable sentinels. Its sign therefore
required a targeted repeat rather than accepting the apparent 5.735% result
at face value.

### Targeted mirrored confirmation

Three cells were repeated with eight phases each:

    A1 B1 B2 A2 B3 A3 A4 B4

This tested the previously noisy `mixed/tag-bytes`, the higher-variance
`rich/tag-bytes`, and the small-effect `mixed/coordinates` cell.

| Path | Profile | A10a mean | A10b mean | A10b vs A10a | first half | second half |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| tag bytes | mixed | 128.124 | 121.040 | -5.529% | -5.107% | -5.950% |
| tag bytes | rich | 369.321 | 364.788 | -1.227% | -1.907% | -0.541% |
| coordinates | mixed | 85.451 | 83.602 | -2.165% | -2.147% | -2.182% |

The targeted run used 24 sentinels:

    min       225.009 ns/node
    median    225.982 ns/node
    max       231.653 ns/node
    max/min     2.953 %

All repeated phases again retained identical checksums.

`mixed/tag-bytes` continued to show two A10a timing bands, so its approximate
5.5% magnitude should not be interpreted as a clean estimate of the isolated
optimization cost. What is durable is that both independently ordered halves
favored A10b, while the candidate itself remained in a much tighter timing
band.

### Static code generation

A10b further reduced executable `.text`:

    A10a baseline    1,204,077 bytes
    A10b candidate   1,202,989 bytes
    delta               -1,088 bytes

The initially inspected relevant symbol changes were localized to the expected
range/sink machinery:

    DenseTagRange.fromValidated    -515 bytes
    TagIdSink.put                  -312 bytes
    TagByteSink.put                -312 bytes

The coordinate path benefits through the eager first-pair decode performed by
`DenseTagRange.fromValidated()`. Tag-consuming paths additionally benefit when
subsequent `popFront()` operations decode the remaining pairs.

### A10b classification

A10b is **KEEP**.

The decision rests on the combination of:

1. a narrow construction-controlled validated-state premise;
2. no weakening of hostile-input validation at the public cursor boundary;
3. retained defensive `StringTableView.get()` bounds checking;
4. DMD and LDC correctness validation;
5. reduced generated code size;
6. a stable-gated full matrix with all nine cells favoring A10b;
7. checksum identity across baseline and candidate; and
8. targeted mirrored confirmation of the three noisier or smaller-effect
   cells.

The precise percentage for `mixed/tag-bytes` remains intentionally
unclaimed because of its bimodal baseline. The retained engineering conclusion
is that removing this duplicate SID validation is semantically justified,
reduces code size, and has no observed performance regression under the
controlled benchmark set.

## A11-Bench: DenseInfo semantic workload contract

A11 starts with measurement infrastructure before any DenseInfo production
optimization.

This step changes only the DenseNodes D microbenchmark and its conservative
C++20 semantic reference. No production source under `source/` is changed.

### Motivation

The pre-A11 DenseNodes benchmark covered tags and coordinates but generated no
DenseInfo. The C++ reference likewise explicitly refused metadata-bearing
workloads. Optimizing `DenseInfoNodeCursor` under that contract would therefore
have produced measurements that did not exercise the code under investigation.

A11-Bench closes that gap before changing production code.

### Workload profiles

The historical A2-A10 profiles remain unchanged:

- `tagless`: no tags and no DenseInfo;
- `typical`: two tags per node and no DenseInfo;
- `rich`: eight tags per node and no DenseInfo;
- `mixed`: deterministic mixed tag counts and no DenseInfo.

Three explicit metadata profiles are added:

- `info-only`: zero tags plus all six DenseInfo columns;
- `typical-info`: two tags per node plus all six DenseInfo columns;
- `rich-info`: eight tags per node plus all six DenseInfo columns.

`--profile=all` intentionally remains the historical four-profile set. This
preserves direct reproducibility of the A2-A10 benchmark series; A11 metadata
profiles are selected explicitly.

The canonical performance workload stores each DenseInfo column in one packed
occurrence. Packed/unpacked compatibility remains part of decoder correctness
rather than multiplying the primary performance matrix.

The generated metadata contains:

- direct `version`;
- delta-coded `timestamp`;
- delta-coded `changeset`;
- delta-coded `uid`;
- delta-coded `user_sid`;
- direct `visible`, set to `true` for every generated metadata-bearing node;
- the default `date_granularity` of 1000; and
- a borrowed `"benchmark-user"` StringTable entry at SID 17.

### Observable metadata contract

DenseInfo is consumed by all three sink paths whenever present.

The checksum mixes:

1. all six `has*` presence flags;
2. `version`;
3. cumulative `timestampValue`;
4. exact `timestampMillis`;
5. cumulative `changeset`;
6. cumulative `uid`;
7. cumulative `userSid`;
8. borrowed username length;
9. first and last username byte when non-empty; and
10. `visible`.

An independent `infoCount` is carried through `DecodeRun`, warm-up validation,
timed aggregation, and workload self-validation. A metadata-bearing path
therefore cannot silently stop observing DenseInfo while still satisfying the
benchmark consistency checks.

Tag-ID and tag-byte sinks additionally retain their existing tag observations.

### Semantic-reference contract

`benchmark/reference/dense_nodes_cpp.cpp` now implements DenseInfo rather than
using the previous empty metadata cursor.

Its metadata path mirrors the relevant production semantics:

- complete DenseInfo preflight before the first emitted node;
- independently optional columns;
- packed and unpacked repeated scalar decoding;
- present-column length equal to `nodeCount`;
- checked timestamp, changeset, uid, and user_sid delta accumulation;
- cumulative uid constrained to the schema `int32` domain;
- cumulative user_sid constrained to the indexed StringTable;
- checked timestamp scaling by `date_granularity`;
- six streaming column cursors during emission;
- borrowed username bytes from the StringTable; and
- no metadata materialization arrays.

The C++ reference remains conservative for coordinate emission: unlike current
D production it retains per-node checked coordinate arithmetic. It is therefore
a semantic and comparative reference, not a claim of cycle-for-cycle identical
generated code.

### Initial semantic gate

Before any A11 performance experiment:

- the D DenseNodes benchmark built successfully with LDC;
- the C++20 reference built successfully with both GCC and Clang;
- seven profiles were exercised:
  `tagless`, `typical`, `rich`, `mixed`, `info-only`, `typical-info`,
  `rich-info`;
- each profile was exercised through `coordinates`, `tag-ids`, and
  `tag-bytes`; and
- D, GCC C++, and Clang C++ produced identical observable checksums for every
  profile/path combination.

That is 21/21 semantic checksum cells matching for each independently compiled
C++ reference.

The historical `--profile=all` expansion was also verified on both D and C++ as
exactly:

    tagless
    typical
    rich
    mixed

### Benchmark-fixture correction

The first A11-Bench implementation generated the direct `visible` column as
alternating `true`/`false` values in both the D workload builder and the C++20
semantic reference. Because the same fixture defect existed independently of
the decoder under test in both benchmark implementations, D/GCC/Clang checksum
parity could not detect it.

The intended synthetic A11 metadata contract is now explicit: every generated
metadata-bearing node has `hasVisible == true` and `visible == true`. The D and
C++ workload builders therefore encode `1` for every generated `visible`
value.

After correcting the fixture:

- the four historical `tagless`, `typical`, `rich`, and `mixed` profiles remain
  unchanged;
- the observable checksums of the three metadata profiles change as expected;
- D, GCC C++, and Clang C++ again match in all 21 profile/path checksum cells;
  and
- the historical `--profile=all` expansion remains exactly the original four
  A2-A10 profiles.

Performance measurements made with the pre-correction A11 binaries are retained
only as exploratory evidence and are not used as the frozen baseline for an A11
production optimization. Baseline and candidate binaries must both be rebuilt
from the corrected benchmark contract before a performance decision is made.

### Classification

A11-Bench is retained as benchmark infrastructure.

The short smoke-run timings used while establishing semantic parity are **not**
an A11 performance baseline and support no performance conclusion. Their sole
purpose was to prove that the new paths execute and produce the same observable
semantics.

The first production A11 optimization must start from a frozen build of this
benchmark contract and be measured separately against that fixed baseline.

## A11a: DenseInfo prevalidated semantic-check elision

A11a applies the same validated-state principle already retained for DenseTags
to DenseInfo emission.

`validateDenseInfo()` completes semantic preflight before the first DenseNode is
published. For the exact same `PrimitiveBlockLayout`, `PrimitiveGroupLayout`,
and `StringTableView` backing, it has already proved:

- cumulative timestamp delta arithmetic;
- timestamp scaling by `date_granularity`;
- cumulative changeset arithmetic;
- cumulative UID arithmetic and the signed 32-bit UID domain;
- cumulative `user_sid` arithmetic and StringTable-ID range; and
- DenseInfo column cardinality.

The public `DenseInfoNodeCursor.nextNode()` remains defensive. A package-internal
`nextPrevalidatedNode()` is used by production DenseNodes emission only after
successful complete DenseInfo validation for the same unchanged backing.

The prevalidated path omits only the semantic arithmetic/domain checks already
proved by preflight. It deliberately retains:

- wire decoding and cursor failure handling;
- per-column presence/cardinality observation;
- the remaining-node guard;
- `StringTableView.get()` username materialization/bounds checking; and
- the existing final `finish()` checks.

This is a Level-1 validated-state provenance optimization: correctness depends
on successful prior validation plus unchanged backing and preserved provenance.

### Correctness and binary-size gate

The A11a candidate was rebuilt against the corrected A11 benchmark contract
introduced by commit `080855f`.

Baseline and candidate:

- used the same corrected benchmark sources;
- were compiled with LDC 1.41.0 / LLVM 19.1.7;
- used `--x86-branches-within-32B-boundaries`;
- matched in all 21 DenseNodes profile/path semantic checksum cells; and
- passed the existing DMD and LDC unit-test suites.

The benchmark executable `.text` size changed from 1,214,901 bytes to
1,211,149 bytes, a reduction of 3,752 bytes.

### Controlled performance result

The final decision run used CPU 5 pinned at 2.6 GHz with the SMT sibling
offline, turbo disabled, and the `performance` governor. Each of the nine
DenseInfo profile/path cells used an A-B-B-A sequence with a baseline sentinel
before every phase.

Raw candidate deltas were:

| Profile | Path | Candidate vs baseline |
| --- | --- | ---: |
| `info-only` | `coordinates` | -7.147% |
| `info-only` | `tag-ids` | -8.186% |
| `info-only` | `tag-bytes` | -7.597% |
| `typical-info` | `coordinates` | -5.108% |
| `typical-info` | `tag-ids` | -4.899% |
| `typical-info` | `tag-bytes` | -3.985% |
| `rich-info` | `coordinates` | -3.678% |
| `rich-info` | `tag-ids` | -3.560% |
| `rich-info` | `tag-bytes` | -3.205% |

All nine raw cells favored A11a. Both mirrored A/B halves also favored A11a in
every cell.

A secondary normalization divided each phase result by its immediately
preceding baseline sentinel. All nine normalized cells still favored A11a, with
normalized deltas ranging from -2.499% to -8.351%.

The global sentinel max/min spread was 3.536%, so the mechanical 3% sentinel
gate is recorded as `REVIEW`, not `PASS`. Only three of 36 sentinels were more
than 1% from the median and two were more than 2% from it. The sentinel
excursions did not reverse any raw mirrored comparison, and sentinel
normalization preserved the candidate advantage in all nine cells.

### Classification

**KEEP.**

A11a removes checks whose exact semantics were already proved by complete
DenseInfo preflight, preserves the public defensive API and remaining
materialization/wire checks, reduces generated code size, and shows a
consistent performance improvement across every corrected DenseInfo workload.
The measured percentages describe this controlled benchmark setup and are not
claimed as universal application-level speedups.

## A11b: canonical packed DenseInfo column reuse

A11b investigated whether DenseInfo structural information discovered during
preflight could be reused during emission.

The experiment started from the retained A11a baseline at commit `a5edcf9`.
A11a already removes repeated semantic checks after complete DenseInfo
validation. A11b targeted a different remaining cost: locating the six
DenseInfo column streams themselves.

### Hypothesis

The generic emission path uses six independent `DenseInfoColumnCursor`
instances for `version`, `timestamp`, `changeset`, `uid`, `user_sid`, and
`visible`.

Complete DenseInfo preflight has already traversed the same serialized
structure before the first node is emitted. A11b therefore tested preserving
the packed-column locations discovered during validation and using them to seed
the emission cursors directly.

Legal non-canonical protobuf representations had to continue using the generic
decoder. Canonical layout was an optimization capability only, never a
validity requirement.

### Real-corpus shape

Six real PBF extracts were profiled:

- Geofabrik Monaco;
- Geofabrik Andorra;
- Geofabrik Liechtenstein;
- openstreetmap.fr Monaco;
- openstreetmap.fr Andorra; and
- openstreetmap.fr San Marino.

Aggregate DenseInfo population:

    groups                210
    nodes           1,658,095
    mean nodes/group   7,895.69

All 210 observed DenseInfo groups had the researched canonical form:

- one DenseNodes message per group;
- one DenseInfo message;
- fields 1-5 packed once in ascending order;
- no `visible` field;
- no unknown DenseInfo field; and
- no wrong wire type.

Provider diversity does not by itself establish independent writer diversity,
but the canonical shape was universal in this sampled corpus.

### v1: rejected template-axis design

The first implementation introduced a dedicated canonical DenseInfo cursor and
a compile-time `CanonicalInfo` dispatch axis.

The cursor representation itself was substantially smaller:

    generic cursor      896 bytes
    canonical cursor    256 bytes

However, DenseNodes dispatch specializations increased from 12 to 18 and
actual executable `.text` grew from:

    baseline      746,784 bytes
    A11b v1       885,536 bytes
    delta        +138,752 bytes  (+18.58%)

Approximately 136 KiB of that increase was attributable to the expanded
dispatch family.

A11b v1 was therefore classified **REWORK** before performance timing.

### v2: runtime-selected canonical layout

A11b v2 removed the compile-time canonical axis.

Preflight instead produced a package-internal canonical layout containing
packed offset/length spans, a presence mask, and canonical-layout provenance.
On the measured target the layout occupied 52 bytes.

`DenseInfoNodeCursor.fromPrevalidatedLayout()` selected once during cursor
construction between:

1. the existing generic protobuf traversal; and
2. direct packed-column cursors seeded from the preflight-proven spans.

The compile-time axes remained only:

    HasTags × HasInfo × Sink

There was no per-node canonical branch and no new public API.

The measured candidate diff SHA-256 was:

    3168cc46c95d342529f3eb7982178fb03919e092f582e2c1b2b642f47eec4903

### Correctness and static-size gate

A11b v2 passed:

- DMD tests;
- LDC tests;
- LDC release build; and
- all 21 synthetic DenseNodes profile/path semantic checksum cells.

The candidate retained exactly 12 DenseNodes dispatch specializations.

Actual executable `.text` changed from:

    A11a baseline    746,784 bytes
    A11b v2          748,960 bytes
    delta             +2,176 bytes  (+0.291%)

The v1 code-size failure was therefore removed, but the remaining complexity
still required measurable runtime justification.

### Fixed-cost amplification

Initial measurements at 4,096-200,000 nodes/group showed only noisy
sub-percent differences.

A deliberately amplified experiment then used canonical info-only groups of:

    16
    64
    256
    1,024

nodes while keeping total decoded work approximately constant.

All four sizes favored the candidate in both raw and normalized comparisons.
Regression against `1/N` produced approximately:

    fixed saving/group      1.57 us
    R^2                     0.997

This confirms the hypothesized fixed per-group saving.

The mechanism is therefore real. The problem is its amortization: at the
real-corpus mean of approximately 7,896 nodes/group, a few microseconds of
saved group setup become a very small per-node effect.

### Real-PBF semantic gate

A disposable real-data harness prepared PBF framing, Blob decoding,
decompression, PrimitiveBlock layout, StringTable indexing, and PrimitiveGroup
layout outside the timed region.

The prepared corpus contained:

    files                       6
    OSMData blocks            236
    DenseNodes groups         210
    DenseInfo nodes     1,658,095

Both the frozen A11a baseline and A11b v2 decoded every real group through the
production `decodeDenseNodes` entry point.

Per-file output and aggregate output were identical. The common aggregate
checksum was:

    10687467426028546419

Thus real-PBF semantic parity passed for all 1,658,095 DenseInfo nodes.

### Real-PBF A-B-B-A timing

The controlled run used CPU 5 fixed at 2.6 GHz, its SMT sibling offline,
turbo disabled, and the `performance` governor.

Phase medians:

| Phase | ns/node |
| --- | ---: |
| A1 | 286.108653 |
| B1 | 285.518845 |
| B2 | 285.004847 |
| A2 | 285.556709 |

Direct comparison:

    A mean               285.832681 ns/node
    B mean               285.261846 ns/node
    raw B vs A               -0.1997%
    mirrored half 1          -0.2061%
    mirrored half 2          -0.1933%
    apparent saved/group     +4.507 us

Both raw mirrored halves favored the candidate.

However, sentinel normalization reversed the result to `+0.1786%`. The four
sentinel medians had only 0.652% max/min spread, but the final sentinel moved
without a corresponding shift in the immediately following A2 phase.

At an effect size near 0.2%, this normalization was too sensitive to serve as
the deciding statistic. The run therefore showed a possible small benefit,
not a robust KEEP result.

### Paired real-PBF replication

A second experiment used eight direct A/B pairs with alternating order.

All semantic observations remained identical.

Two baseline processes, pairs 2 and 8, entered a distinct approximately
417 ns/node regime while normal processes were approximately 284-288 ns/node.
Because the whole process phase shifted rather than isolated samples, those
runs represent a different execution state and make the eight-pair aggregate
unsuitable for estimating A11b.

The six pairs remaining in the normal timing regime were:

| Pair | B vs A |
| --- | ---: |
| 1 | -0.2715% |
| 3 | -0.4547% |
| 4 | +0.1741% |
| 5 | -0.3758% |
| 6 | +0.1106% |
| 7 | +0.7067% |

Descriptively:

    candidate faster     3/6
    baseline faster      3/6
    mean B vs A         -0.0184%
    median B vs A       -0.0805%
    range               -0.4547% .. +0.7067%

These six observations are not promoted to a replacement formal estimator.
They demonstrate only that, once the clearly different 417 ns/node process
state does not dominate the arithmetic, the real-data measurements show no
robust directional advantage.

### Classification

**DROP.**

A11b established that:

1. canonical packed DenseInfo is common in the sampled corpus;
2. preflight-discovered packed spans can eliminate a real fixed per-group cost;
3. the small-group `1/N` experiment demonstrates that mechanism strongly; and
4. the runtime-selected v2 avoids the unacceptable template expansion of v1.

However, the measured real workload contains approximately 7,896 DenseInfo
nodes per group. At that scale the fixed saving is heavily amortized.

No reproducible real-PBF advantage remained above ordinary sub-percent
run-to-run variation, while the candidate still added generated code,
canonical-layout provenance, and a second cursor-construction path.

The tradeoff therefore does not satisfy the project's requirement that
hot-path complexity be justified by reproducible benchmark evidence on an
actual consumer workload.

The A11b production changes are not retained. Production remains at the A11a
implementation from `a5edcf9`.

This negative result is retained deliberately. The idea should be reconsidered
only if a future measured consumer has materially smaller DenseInfo groups, or
if preflight structure can be reused with substantially less additional
production complexity.
