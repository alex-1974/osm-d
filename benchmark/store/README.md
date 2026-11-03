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
associative-array primary indexes.

Both reference and compact variants also carry the **same** packed
benchmark-only parent indexes:

- Node -> parent Ways;
- typed element -> parent Relations.

This prevents #62 from winning by omitting reverse navigation while leaving the
production #63 parent-index representation open.

The benchmark-only parent index is not a supported store API.

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

For the compact variant the benchmark feeds the selected layout from validated
borrowed semantic reader views. This is **qualification machinery only**: it
exists so #62 can measure the retained layout instead of obsolete M4
materialization heap pages. Production public direct PBF construction remains
#64.

`owned_bytes` is logical owned representation size and is reported separately
from allocator-inclusive RSS.

## Accepted Bremen result

LDC 1.41.0, GitHub Ubuntu 24.04 hosted runner, release/allAtOnce:

| Metric | Reference | Compact |
| --- | ---: | ---: |
| Final incremental RSS | 950,452 KiB | 345,208 KiB |
| Logical owned bytes incl. parent index | 693,270,944 | 316,034,245 |
| Node lookup p50 | 102.236 ms | 78.676 ms |
| Way lookup p50 | 13.387 ms | 10.108 ms |
| Relation lookup p50 | 0.849 ms | 0.574 ms |
| Node-parent lookup p50 | 40.018 ms | 41.901 ms |
| Relation-parent lookup p50 | 2.713 ms | 2.862 ms |
| Full traversal p50 | 137.235 ms | 174.761 ms |
| 10k edits | 6.368 ms | 19.130 ms |
| Parent-index rebuild after edits | 377.127 ms | 363.129 ms |
| Revert batch | 0.482 ms | 5.472 ms |

All semantic, edit, revert and remap checksums matched.

Memory decision:

- RSS reduction: **63.680%**;
- logical owned-byte reduction: **54.414%**;
- <=75% reference-RSS gate: **PASS**;
- <=512 MiB city budget: **PASS**;
- <=384 MiB stretch budget: **PASS**.

The GitHub workflow
`.github/workflows/store-layout-qualification.yml` reproduces this gate and
uploads the three raw result files plus the decision summary as an artifact.

Large PBF inputs and raw result files remain uncommitted.
