# ADR 0022: compact editable store layout

- Status: Accepted
- Date: 2026-11-03
- Related: #46, #61, #62, #63, #64
- Supersedes: none

## Context

ADR 0021 fixed the semantic and workload contract for the M6 editable OSM
store without choosing a physical representation. #62 must now select one
production layout using the pinned city/editor workload rather than isolated
`sizeof` results.

The relevant constraints are:

- exact Node/Way/Relation semantics from M4/M5;
- stable opaque handles across ordinary edits;
- expected O(1) typed ID lookup;
- deterministic per-type traversal;
- compact ownership of tags, metadata, Way references and Relation members;
- lazy baseline state for edited loaded objects;
- no Dunia-specific application state;
- no mandatory persistence or mmap format in the first M6 scope;
- enough representation freedom for #63 parent indexes and #64 direct PBF
  construction.

## Decision

### Public abstraction

The supported consumer abstraction is `OsmStore` through `osm.store` and
the package root.

Consumers see:

- OSM identities and semantic views;
- stable opaque `OsmHandle` values;
- typed ID lookup;
- deterministic Node/Way/Relation traversal;
- complete replacement;
- create/delete/restore/revert lifecycle state;
- logical memory accounting.

The public API does not expose SoA terminology, pool offsets, hash-table slots,
allocator details or PBF representation types.

### Fixed fields: columnar storage

Fixed-width element state is stored in parallel columns.

Examples include:

- IDs;
- lifecycle/generation state;
- tag spans;
- metadata presence/value columns;
- Node latitude/longitude;
- Way child spans;
- Relation member spans.

This avoids an object allocation per OSM element and keeps high-volume fields
dense.

### Variable children: append-only pools

Variable-length data is stored in compact append-only pools referenced by
32-bit offset/length spans:

- tags;
- Way node IDs;
- sparse Way locations;
- Relation member IDs/types/roles.

Replacement appends new child content rather than relocating every later
element. The old segment becomes reclaimable representation slack. Explicit
whole-store compaction remains a later handle-invalidating maintenance
operation; ordinary edits never move unrelated elements.

### Strings: shared interning

Tag keys/values, usernames and Relation roles share one interned byte pool.
Elements and child records store compact string IDs rather than one owned D
array per occurrence.

This is the main representation win on city-scale tagged data.

### Primary ID lookup

Each OSM element type has its own compact open-addressed ID table:

- Node ID -> slot;
- Way ID -> slot;
- Relation ID -> slot.

The tables keep the ADR 0021 expected-O(1) lookup contract and avoid the
per-entry overhead of D associative arrays in the production layout.

Production reverse/parent indexes remain #63. #62 uses the same packed
benchmark-only parent index on both reference and candidate sides so reverse
navigation is included fairly in the layout decision without pre-empting the
#63 design.

### Stable handles

A handle contains store-local identity, element type, slot and generation.
It is not an address and is never an OSM ID.

Normal replacement, deletion/restore and authoritative ID remapping keep the
handle stable. A handle from another store instance cannot alias a local
element even when type/slot/generation coincide.

### Ownership

The compact core uses an internal deterministic owner backed by
`malloc/realloc/free` rather than the D GC heap.

The unsafe pointer arithmetic is confined to the package-internal
`ManualArray` primitive; its bounds-checked operations are exposed to the
rest of the store through narrow `@trusted` methods. The consumer-facing
store remains `@safe`.

This choice is evidence-driven. The first GC-array candidate reduced logical
owned bytes substantially but retained hundreds of MiB of dead city-build
heap pages in process RSS after the M4 `PbfDocument` intermediate had become
unreachable. A compact store whose logical representation is small but whose
allocator cannot return the relevant memory did not satisfy the editor memory
goal.

### Bulk construction

`OsmStore.build` pre-scans an owned dataset for element/child/string counts
and reserves the compact columns and pools once. Incremental `add` remains
available for ordinary edits.

A package-internal format-neutral borrowed-view ingest path is retained as
qualification machinery. It consumes semantic Node/Way/Relation views and is
used by the #62 benchmark to measure retained store RSS without charging an
obsolete `PbfDocument` object graph to the candidate.

That path is **not** the public #64 PBF-to-store API. #64 remains responsible
for production direct construction, reader orchestration, bounded temporary
memory and final construction qualification.

### Editing

Loaded objects capture an owned baseline only on first edit. Current compact
content is appended into the shared pools; revert restores the semantic
baseline.

This makes the edit path slower than direct replacement in the straightforward
object-graph reference but keeps the baseline proportional to the edited
subset and preserves stable slots.

The package-internal `remapKnown` kernel proves the layout can rewrite a local
ID and known inbound references while retaining the handle. #63 will supply
those inbound locations from production parent indexes and expose the complete
coherent operation.

### No mir.ndslice dependency

`mir.ndslice` is not used. The selected representation needs owned mutable
columns, compact child pools, hash indexes and lifecycle mutation; a generic
multidimensional-slice abstraction does not materially simplify those
requirements.

## Bremen qualification

Decision corpus:

- `bremen-260901`;
- Geofabrik snapshot 2026-09-01;
- 21,159,666-byte PBF;
- SHA-256
  `52bc46f09ce1f1198b95de308aba10c1b59108c9fdbb827fea305f7316b4ea0e`;
- 1,662,874 Nodes;
- 328,626 Ways;
- 5,985 Relations.

Qualification environment:

- GitHub Ubuntu 24.04 hosted runner;
- LDC 1.41.0;
- release, `allAtOnce`;
- fresh process per retained-layout variant;
- identical packed benchmark-only parent index on both variants.

All semantic, edit, revert and local-ID-remap checksums matched.

| Metric | Straight reference | Compact layout | Compact vs ref |
| --- | ---: | ---: | ---: |
| Final incremental RSS | 950,452 KiB | 345,208 KiB | **-63.680%** |
| Logical owned bytes incl. parent index | 693,270,944 | 316,034,245 | **-54.414%** |
| Node lookup, p50 / 1M | 102.236 ms | 78.676 ms | -23.0% |
| Way lookup, p50 / 250k | 13.387 ms | 10.108 ms | -24.5% |
| Relation lookup, p50 / 50k | 0.849 ms | 0.574 ms | -32.4% |
| Node-parent lookup, p50 / 250k | 40.018 ms | 41.901 ms | +4.7% |
| Relation-parent lookup, p50 / 100k | 2.713 ms | 2.862 ms | +5.5% |
| Full semantic traversal, p50 | 137.235 ms | 174.761 ms | +27.3% |
| 10,000-operation edit batch | 6.368 ms | 19.130 ms | +200.4% |
| Parent-index rebuild after edits | 377.127 ms | 363.129 ms | -3.7% |
| Revert edited batch | 0.482 ms | 5.472 ms | +1036% |

The edit/revert percentages look large because the straightforward reference
replaces pre-prepared owned objects directly. The compact candidate performs
string interning, pool append and lazy baseline work. The absolute candidate
cost is still about 19 ms for 10,000 edits and about 5.5 ms for the complete
revert batch.

The full traversal regression is accepted deliberately. Editor navigation is
dominated by random typed lookup and local topology queries, where the compact
layout is neutral or faster. A complete Bremen semantic scan remains below
0.2 s on the hosted runner. Adding a second traversal representation solely to
win a full-scan benchmark would work against the primary memory goal.

### Memory gates

The compact candidate passes all #61 layout gates:

- reference ratio: 36.3204% of final incremental RSS, target <=75%;
- final incremental RSS: 337.117 MiB, target <=512 MiB;
- stretch target <=384 MiB: PASS.

For early #64 evidence only, the qualification-only borrowed-ingest run peaked
at 443,140 KiB against 345,208 KiB final incremental RSS, approximately 1.284x.
This does not close #64 because that issue still owns the public production
construction path and its complete qualification.

### Materialized build cost

A third fresh process measured only the fair
`OwnedDataset -> store representation` construction after the same
`PbfDocument` source decode:

- straightforward reference layout build: 310.963 ms;
- compact layout build: 807.133 ms.

The roughly 496 ms one-time extra construction work is accepted for the
measured memory reduction and faster primary lookup. #64 may reduce end-to-end
load cost by eliminating the materialized intermediate entirely.

## Consequences

- The selected layout is production code, not a research-only candidate.
- The store has deterministic ownership independent of the GC for its
  high-volume compact core.
- Stable consumer handles are decoupled from physical addresses and OSM IDs.
- String interning and compact pools materially reduce city-scale memory.
- Full-store traversal and edit/revert are slower than the straightforward
  object graph, but remain small in absolute editor-scale time.
- Parent-index mutation/coherence is still #63.
- Public direct PBF-to-store construction is still #64.
- Persistence/mmap remains deliberately unfrozen.
