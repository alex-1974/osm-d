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
