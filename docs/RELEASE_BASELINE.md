# osm-d v0.1.0 release baseline

**Baseline date:** 2026-11-04

This document condenses the evidence used to qualify the first standalone
osm-d release. It is intentionally a release-facing baseline rather than a new
research program. Absolute timings are environment-specific; the durable
claims are the stated semantic parity, bounded-memory behavior, supported
compiler matrix and the measured performance class on the recorded runners.

## Supported toolchain and platform

Source-compatibility floor:

- D frontend 2.111;
- DUB 1.40.0.

Release compiler matrix:

- DMD 2.111.0, 2.112.1, 2.113.0;
- LDC 1.41.0, 1.42.0, 1.43.0.

The v0.1.0 release gate is Ubuntu 24.04 x86_64. Other platforms are not
claimed as release-qualified by this baseline.

LDC 1.41.0 is the primary release-performance compiler. Quantitative values
below use release builds and state additional build details where material.

The supported source API and direct-import boundary are defined separately in
`API_STABILITY.md`.

## Pinned compatibility corpus

All real-data release evidence uses the Geofabrik 2026-09-01 snapshot.

| Dataset | Compressed bytes | SHA-256 |
| --- | ---: | --- |
| Monaco | 690,567 | `f2d904ee0aa156a2252c39c0ab80ca7b3fafb28da6a84b909084a26f068ac962` |
| Liechtenstein | 3,451,831 | `69e694d15ac822665381bf47fa8a5f437b3c0c3d72af458727f94e131930d818` |
| Bremen | 21,159,666 | `52bc46f09ce1f1198b95de308aba10c1b59108c9fdbb827fea305f7316b4ea0e` |
| Austria | 808,820,532 | `0bfa5f1db8a468b3792b1ead07b56d4f7a8c456e500d23dc8d3083e82508dfb8` |

The manifest and fetch/checksum tooling live under `benchmark/datasets` and
`benchmark/fetch-datasets.sh`.

## Parser correctness/reference evidence

The complete semantic decode-count workload was checked against libosmium
2.23.0 on all four pinned datasets.

| Dataset | Nodes | Ways | Relations | Tags | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Monaco | 41,703 | 6,249 | 348 | 44,946 | PASS |
| Liechtenstein | 361,543 | 42,051 | 973 | 210,505 | PASS |
| Bremen | 1,662,874 | 328,626 | 5,985 | 2,073,595 | PASS |
| Austria | 87,627,541 | 9,359,891 | 180,296 | 43,979,849 | PASS |

This is semantic parity for the common decode/count contract. It is not a
claim that osm-d and libosmium execute identical internal work.

## PBF reader baseline

Bremen reader qualification used LDC 1.41.0, release/allAtOnce, on a GitHub
Ubuntu 24.04 runner exposing four logical CPUs. Serial and parallel summaries
matched exactly.

| Mode | p50 elapsed | Speedup vs serial | p50 peak RSS |
| --- | ---: | ---: | ---: |
| serial `PbfReader` | 700.879 ms | 1.00x | 28,580 KiB |
| parallel, 1 worker | 728.658 ms | 0.96x | 33,188 KiB |
| parallel, 2 workers | 387.254 ms | 1.81x | 34,104 KiB |
| parallel, 4 workers | 330.516 ms | 2.12x | 46,456 KiB |

The retained reader-orchestration comparison measured 695.884 ms for the
previous direct orchestration and 697.025 ms for production `PbfReader`
(+0.164%), with identical outputs. That run classifies the public reader
boundary as performance-neutral; its absolute time is not used as a cross-host
throughput promise.

### Reader allocation/memory evidence

On Bremen, one reusable `PbfReaderWorkspace` measured:

- first complete read while scratch grew: 4,694,192 D-GC bytes;
- second complete read: 0 D-GC bytes, 0 collections;
- third complete read: 0 D-GC bytes, 0 collections;
- dedicated-process peak RSS: 28,512 KiB.

On the 808,820,532-byte Austria workload:

- first read: 11,067,568 D-GC bytes;
- second read with the same workspace: 0 D-GC bytes, 0 collections;
- process peak RSS: 807,020 KiB.

These measurements support the stated steady-state reuse contract; they do not
claim that loading the complete input buffer itself is allocation-free.

## Compact editable store baseline

The final M6 Bremen qualification uses LDC 1.41.0, Ubuntu 24.04,
release/allAtOnce. Production reverse indexes are maintained incrementally.

Parent-index qualification:

| Metric | Static reference | Production compact |
| --- | ---: | ---: |
| parent-index logical bytes | 78,577,608 | 73,415,112 |
| Node -> Way p50 / 250k | 31.746 ms | 64.680 ms |
| typed -> Relation p50 / 100k | 2.952 ms | 3.461 ms |
| 10k edit batch | 5.509 ms | 29.210 ms |
| full parent rebuild after edits | 396.032 ms | **0 ms** |
| final incremental RSS | 948,460 KiB | 351,324 KiB |
| total logical owned bytes | 691,378,472 | 308,976,077 |

Direct PBF-to-store construction on the same pinned Bremen input:

- direct PBF -> fully indexed store: **2,268.417 ms**;
- materialized PBF -> `PbfDocument`: **4,139.849 ms**;
- materialized `OwnedDataset` -> compact store: **1,045.288 ms**;
- combined materialized path: **5,185.137 ms**, or 2.285795x direct;
- final incremental RSS: **357,908 KiB = 349.520 MiB**;
- peak incremental RSS: **383,104 KiB**;
- peak/final ratio: **1.070398x**;
- logical owned bytes: **308,976,077**;
- production parent-index bytes: **73,415,112**.

The direct path therefore passes the M6 <=1.5x peak/final target, the 512 MiB
city target, and the 384 MiB stretch target.

## PBF writer and OSM XML baseline

The release-only I/O probe was measured at candidate
`cadaa15fd170cdb5201b54a26ae65685401d2a50` on GitHub Ubuntu 24.04 with
LDC 1.41.0, release/allAtOnce. The pinned Monaco input was used; each reported
operation is the median of five runs.

| Operation | p50 |
| --- | ---: |
| semantic PBF write | **136.201 ms** |
| OSM XML write | **273.119 ms** |
| materializing OSM XML read | **1,113.736 ms** |

The input contained 41,703 Nodes, 6,249 Ways and 348 Relations. Generated
sizes were 2,496,211 bytes for the current semantic PBF writer and 11,584,269
bytes for OSM XML. The larger PBF output is representation-dependent and is not
a compression-ratio claim.

Both generated formats were read back and compared to the source
`OwnedDataset`; semantic parity passed. The reproducible probe is
`benchmark/release/io_baseline.d` and the Release Gate uploads its raw
key/value output.

No separate osmChange throughput number is published for v0.1.0: its release
contract is semantic/editor interoperability and upload validation, not
high-volume bulk parsing. The feature is still covered by unit, external
consumer and osmium-tool interoperability gates.

## Release interpretation

The values above are regression evidence for a specific compiler/platform and
pinned corpus. They are not latency SLAs and should not be compared across
uncontrolled hosts as though they were identical benchmarks.

Release claims remain narrower than the implementation:

- low-level wire/codec modules are not compatibility-frozen;
- no persistent/mmap store format is promised;
- store mutation is single-writer/external-sync;
- direct PBF store construction is deliberately serial at the publication
  boundary because the measured path already meets the memory/performance
  target;
- platform qualification beyond Ubuntu 24.04 x86_64 remains future evidence.
