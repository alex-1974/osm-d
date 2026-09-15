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
