# Compact store benchmarks

The M6 store workload contract is defined in
`../../docs/design/compact-store-contract.md`; the selected layout is recorded
in ADR 0022.

## Decision workload

The primary #62 decision corpus is the pinned `bremen-260901` Geofabrik
snapshot from 2026-09-01.

The benchmark executable is:

```text
benchmark/bin/osm-d-bench-store-layout
```

Build with the performance compiler:

```sh
dub build \
  --root=benchmark \
  --config=store-layout \
  --compiler=ldc2 \
  --build=release \
  --build-mode=allAtOnce \
  --force
```

The retained-layout comparison uses fresh processes:

```sh
benchmark/bin/osm-d-bench-store-layout \
  --variant=reference \
  benchmark/data/geofabrik-2026-09-01/bremen-260901.osm.pbf

benchmark/bin/osm-d-bench-store-layout \
  --variant=compact \
  benchmark/data/geofabrik-2026-09-01/bremen-260901.osm.pbf
```

A third mode isolates fair construction work from the same already-materialized
semantic source:

```sh
benchmark/bin/osm-d-bench-store-layout \
  --variant=compact-owned \
  benchmark/data/geofabrik-2026-09-01/bremen-260901.osm.pbf
```

`compact-owned` is a build-cost probe only. Its process RSS includes the
`PbfDocument` intermediate and is therefore not used for the retained-store
memory decision.

## Equivalent capabilities

The straightforward reference owns normal `OwnedDataset` objects and D
associative-array primary indexes. Its reverse-navigation baseline is a static
packed distinct-parent index.

The compact variant uses the **production incremental parent indexes** from
ADR 0023:

- Node -> distinct live parent Ways;
- typed element -> distinct live parent Relations.

The benchmark validates production parent-query checksums against the static
reference. The reference rebuilds its packed index after the edit batch; the
production store maintains reverse state inside each mutation and therefore has
no rebuild phase.

## Workloads

The executable measures:

- store construction;
- 1,000,000 Node ID lookups;
- 250,000 Way ID lookups;
- 50,000 Relation ID lookups;
- 250,000 Node -> parent-Way lookups;
- 100,000 typed element -> parent-Relation lookups;
- full semantic traversal;
- a deterministic 10,000-operation edit batch;
- parent-index rebuild after the edit batch;
- complete revert of the edit batch;
- local Node -> Way -> Relation ID remapping.

Query arrays and edit plans are constructed after the retained-store RSS sample
and outside timed regions.

The edit batch contains exactly:

- 4,000 tag edits;
- 2,000 Node coordinate edits;
- 1,500 Way reference-list edits;
- 500 Relation member-list edits;
- 1,000 local creates;
- 1,000 delete/restore operations.

The reference performs the same lazy first-edit baseline capture and deep-copy
replacement semantics as the compact candidate.

## Memory methodology

`final_incremental_rss_kib` is sampled after the common input buffer and
temporary decode/materialization state have been released.

For the compact variant the benchmark now calls the public
`readPbfStore` API. Validated borrowed semantic reader views feed the durable
production store directly, without a `PbfDocument`/`OwnedDataset`
intermediate. The `compact-owned` variant retains that materialized route only
as a comparison baseline.

`owned_bytes` is logical owned representation size and is reported separately
from allocator-inclusive RSS.

## Accepted Bremen result

LDC 1.41.0, GitHub Ubuntu 24.04 hosted runner, release/allAtOnce:

| Metric | Reference | Compact |
| --- | ---: | ---: |
| Final incremental RSS | 948,460 KiB | 351,324 KiB |
| Logical owned bytes incl. parent index | 691,378,472 | 308,976,077 |
| Parent-index bytes | 78,577,608 | 73,415,112 |
| Node lookup p50 | 61.819 ms | 43.862 ms |
| Way lookup p50 | 8.354 ms | 7.209 ms |
| Relation lookup p50 | 0.938 ms | 0.572 ms |
| Node-parent lookup p50 | 31.746 ms | 64.680 ms |
| Relation-parent lookup p50 | 2.952 ms | 3.461 ms |
| Full traversal p50 | 138.807 ms | 170.976 ms |
| 10k edits incl. production parent maintenance | 5.509 ms | 29.210 ms |
| Required parent rebuild after edits | 396.032 ms | **0 ms** |
| Revert batch | 0.437 ms | 10.810 ms |

All semantic, edit, revert and remap checksums matched.

Memory decision:

- RSS reduction: **62.958%**;
- logical owned-byte reduction: **55.310%**;
- <=75% reference-RSS gate: **PASS**;
- <=512 MiB city budget: **PASS**;
- <=384 MiB stretch budget: **PASS**.

The GitHub workflow
`.github/workflows/store-layout-qualification.yml` reproduces this gate and
uploads the three raw result files plus the decision summary as an artifact.

Large PBF inputs and raw result files remain uncommitted.


## Direct-construction qualification

The M6 workflow also runs `--variant=direct-parity` on pinned Monaco and
Liechtenstein before the full Bremen workload. It compares the complete
materialized-reference semantic checksum with the public direct-store checksum.

Accepted 2026-11-04 result:

- Monaco checksum: **18144549377310145839**;
- Liechtenstein checksum: **4453202522050253806**;
- Bremen checksum: **16194738168706093294**;
- Bremen direct build: **2,268.417 ms**;
- Bremen materialized decode + compact build: **5,185.137 ms**;
- materialized/direct wall-time ratio: **2.285795x**;
- direct peak/final incremental RSS ratio: **1.070398x**;
- <=1.5x direct peak target: **PASS**.

The selected production path has one reusable serial reader workspace and no
worker/queue or block-local staging-store memory. ADR 0024 records why M6 does
not add a parallel owned-staging API without a measured need.
