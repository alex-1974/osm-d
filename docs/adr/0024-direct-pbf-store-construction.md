# ADR 0024: direct PBF construction of the compact store

- Status: Accepted
- Date: 2026-11-04
- Related: #46, #64, ADR 0017, ADR 0021, ADR 0022, ADR 0023
- Supersedes: none

## Context

M6 requires a durable city-scale store that can be loaded from validated OSM
PBF without first materializing the M4 `PbfDocument` / `OwnedDataset` object
graph.

The existing `PbfReader` already provides the important semantic boundary:

- complete HeaderBlock and OSMData validation;
- one synchronous borrowed semantic view for Node, Way and Relation;
- reusable bounded decode workspace;
- exact metadata, tags, references, roles and optional locations.

ADR 0017 deliberately did not expose borrowed element views across parallel
worker lifetimes. It deferred the first owned-destination decision to #64.

The compact store is deliberately single-writer. A parallel element-construction
path would therefore need either:

1. block-local durable staging stores followed by a second merge/copy into the
   final store; or
2. multiple decode workers contending on one synchronized final-store writer.

Both mechanisms add memory, copy/merge work or locking. They are justified only
if the direct single-writer path is a measured bottleneck.

## Decision

### Public API

The supported direct entry point is:

```d
bool readPbfStore(
    scope const(ubyte)[] input,
    out OsmStore store,
    out PbfReadSummary summary,
    out PbfStoreReadStatus status);
```

It is exported through `osm.store` and the curated `import osm;` root.

The complete PBF byte slice is borrowed only for the call. On success the
returned `OsmStore` owns all durable semantic state and may outlive the input.

`PbfStoreReadStatus` contains independent PBF and store diagnostics. On any
PBF or editable-store semantic rejection the public operation returns false,
publishes no partial store and resets the summary.

### Construction path

`readPbfStore` uses one ordinary `PbfReader` and one reusable
`PbfReaderWorkspace`. Validated borrowed semantic views are copied directly
into the compact columns, child/string pools, primary indexes and production
parent indexes.

It does **not** construct:

- `PbfDocument`;
- `OwnedDataset`;
- one owned object graph per element;
- a worker queue;
- block-local staging stores.

This makes the codec-to-store lifetime boundary explicit without leaking PBF
representation details into the public store API.

### Parallel construction decision

No parallel direct-store mode is selected for M6.

The existing parallel reader remains valuable for validation/summary workloads,
where each worker owns its workspace and the queue is bounded. For durable
store construction, however, the destination is intentionally single-writer.

The measured Bremen direct path already materially outperforms the
materialized path and satisfies the memory budget. Adding an owned parallel
staging/merge layer would therefore be mechanism without a demonstrated
consumer problem.

This does not prohibit a future parallel owned-construction design. Such a
change must preserve deterministic failure ordering, store insertion order,
bounded memory and the single-writer publication contract, and must show a
representative consumer benefit before expanding the public API.

### Temporary-memory bound

The selected path has no producer/worker queue and no worker-local durable
staging. Temporary codec memory is bounded by one reusable
`PbfReaderWorkspace`, whose decompression/StringTable/Way-plan buffers grow to
the largest block requirements encountered during the read.

The high-volume durable store core is owned separately by its deterministic
non-GC containers.

## Semantic qualification

Pinned Geofabrik 2026-09-01 datasets:

- Monaco:
  `f2d904ee0aa156a2252c39c0ab80ca7b3fafb28da6a84b909084a26f068ac962`;
- Liechtenstein:
  `69e694d15ac822665381bf47fa8a5f437b3c0c3d72af458727f94e131930d818`;
- Bremen:
  `52bc46f09ce1f1198b95de308aba10c1b59108c9fdbb827fea305f7316b4ea0e`.

Direct-store and materialized/reference semantic checksums matched:

| Dataset | Reference/direct checksum |
| --- | ---: |
| Monaco | 18144549377310145839 |
| Liechtenstein | 4453202522050253806 |
| Bremen | 16194738168706093294 |

Bremen additionally passed primary-lookup, production-parent-index, edit,
revert and local-ID-remap integrity checks.

## Bremen construction qualification

Environment:

- GitHub Ubuntu 24.04 hosted runner;
- LDC 1.41.0;
- release, `allAtOnce`;
- pinned 21,159,666-byte Bremen PBF.

### Direct production path

- end-to-end direct PBF -> indexed `OsmStore`: **2,268.417 ms**;
- final incremental RSS: **357,908 KiB = 349.520 MiB**;
- peak incremental RSS: **383,104 KiB**;
- peak/final ratio: **1.070398x**;
- logical owned store bytes: **308,976,077**;
- production parent-index bytes: **73,415,112**.

The #61 direct-construction peak target is <=1.5x final store RSS:
**PASS**.

The existing <=512 MiB city target and <=384 MiB stretch target also remain
**PASS**.

### Materialized intermediate path

The same pinned input measured:

- PBF -> `PbfDocument`: **4,139.849 ms**;
- `OwnedDataset` -> compact store: **1,045.288 ms**;
- combined materialized path: **5,185.137 ms**.

The materialized path therefore took **2.285795x** the direct-build wall time
on the qualification runner.

## Consequences

- M6 has a public durable PBF loading path with no mandatory intermediate
  semantic object graph.
- PBF representation and borrowed-view lifetime remain below the store API.
- Direct construction builds primary and parent indexes as elements arrive.
- The selected path has one reusable workspace and no worker/queue memory.
- Parallel owned-store staging remains intentionally unfrozen rather than
  becoming public API without measured need.
- `PbfDocument` remains the correct loss-aware editable bridge for workflows
  that need raw preservation/round-trip semantics; it is simply not required
  to load an `OsmStore`.
