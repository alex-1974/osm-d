# Compact editable store contract and workloads

Issue: #61  
Parent: #46  
Decision record: ADR 0021

## Purpose

This document turns the M6 store goal into measurable consumer workloads. It is
the acceptance contract for layout work in #62, indexes in #63 and direct PBF
construction in #64.

The compact store is an OSM semantic data structure. It is not a renderer,
spatial index, database server, network cache, undo-command framework or Dunia
application state container.

## Required consumer operations

The production store API must make these operations direct and unsurprising:

1. insert validated Node, Way and Relation state;
2. find a live element by typed OSM ID;
3. retain an opaque handle across normal edits and server ID remapping;
4. obtain a borrowed semantic view or explicit owned copy from a handle;
5. replace complete element content;
6. create local negative-ID elements;
7. delete/restore elements through explicit lifecycle state;
8. remap local IDs after authoritative diff-upload results;
9. iterate live Nodes, Ways and Relations deterministically;
10. query Node -> parent Ways;
11. query Node/Way/Relation -> parent Relations;
12. export/construct complete change semantics from current lifecycle state;
13. compact tombstones only through an explicit handle-invalidating operation;
14. report memory/accounting information useful to the store benchmark.

Exact function/type names are chosen in #62. Technical layout names are not
part of the consumer vocabulary unless they materially help the caller.

## Complexity contract

The implementation must provide:

| Operation | Required class |
| --- | --- |
| typed ID -> live handle | expected O(1) |
| handle -> element state | O(1) |
| Node -> parent Ways | expected O(1) lookup + O(result size) |
| element -> parent Relations | expected O(1) lookup + O(result size) |
| replace one element | O(element children/tags + affected parent links) |
| delete one element | O(outgoing children/members + affected indexes) |
| local ID remap | O(number of inbound references + index updates) |
| full per-type traversal | O(number of slots + live children/tags) |

No editor-relevant lookup may require a whole-store scan.

## Ownership and lifetime

All durable element data belongs to the store. PBF/XML buffers and decoder
workspaces may be released once insertion/build completes.

Opaque handles are value identities, not pointers. Borrowed views have explicit
mutation invalidation. Structural mutation is never allowed to turn a stale
pointer/reference into a different logical element.

Copy-on-first-edit baseline state is proportional to the edited subset, not to
the full city dataset.

## Partial data

A city/extract store may contain unresolved **positive** references. Forward
Way/Relation data and reverse index keys retain them exactly.

An unresolved negative/local reference is invalid editable state and is
rejected. This matches the upload-validation contract.

## Mutation consistency

Every successful mutation leaves these mutually consistent:

- current element state;
- primary typed-ID index;
- Node -> Way parents;
- typed element -> Relation parents;
- lifecycle state;
- lazy baseline journal when one exists.

A failed mutation leaves all six unchanged.

## First-scope non-goals

The first M6 store does not promise:

- persistence across process restarts;
- stable serialized/mmap representation;
- concurrent writers;
- lock-free reads during mutation;
- spatial/R-tree indexing;
- history/version archive storage;
- OSM account/workset/UI state;
- automatic topology repair;
- a general undo-command stack.

These can be layered later if real consumers justify them.

## Pinned workload datasets

The store reuses the existing immutable Geofabrik 2026-09-01 manifest.

| Dataset | Role | PBF bytes |
| --- | --- | ---: |
| `monaco-260901` | smoke / CI-capable correctness workload | 690,567 |
| `liechtenstein-260901` | small real workload | 3,451,831 |
| `bremen-260901` | **primary city/editor-scale decision workload** | 21,159,666 |
| `austria-260901` | country stress evidence, not a #62 layout micro-gate | 808,820,532 |

Dataset hashes remain canonical in
`benchmark/datasets/geofabrik-2026-09-01.tsv`.

## Reference baseline

#62 must implement a deliberately straightforward reference with equivalent
consumer capabilities:

- owned semantic element arrays;
- straightforward typed ID lookup;
- straightforward parent indexes;
- the same lifecycle/edit workload.

The reference is a comparison baseline, not intended production code. Comparing
a compact store with an `OwnedDataset` that has no indexes would be unfair.

## Workload A — build

Build the complete store from a pinned PBF.

Record:

- wall-clock build time;
- peak RSS;
- final RSS after build/GC stabilization;
- input bytes;
- store-reported owned bytes by category where measurable;
- Node/Way/Relation counts;
- tag/reference/member counts;
- live/tombstone counts;
- primary-index and parent-index sizes.

Correctness checksum must agree with the semantic reader/reference before timing
results are used for a decision.

## Workload B — primary random lookup

Use a deterministic seed and precomputed query arrays outside the timed region.

Measure separately:

- 1,000,000 Node-ID lookups;
- 250,000 Way-ID lookups;
- 50,000 Relation-ID lookups.

Each set uses 90% existing IDs and 10% deterministic misses. Report p50/p90
wall time per lookup batch and a checksum over returned IDs/semantic fields.

Node volume must not hide Way/Relation lookup behavior in one weighted number.

## Workload C — parent lookup

With deterministic sampled IDs, measure separately:

- 250,000 Node -> parent-Way queries;
- 100,000 typed element -> parent-Relation queries.

The checksum includes parent IDs and result counts. The benchmark must include
keys with zero, one and multiple parents where available.

## Workload D — full traversal

Traverse every live Node, Way and Relation and touch:

- identity and coordinates;
- metadata presence/value fields;
- every tag key/value;
- every Way node reference;
- every Relation member type/ID/role.

Report wall time and checksum. A layout may not win by skipping semantic data.

## Workload E — representative edit batch

Prepare the edit plan outside the timed region. Apply 10,000 deterministic
operations drawn from existing city objects:

- 4,000 tag-set replacements/updates across all element types;
- 2,000 Node coordinate edits;
- 1,500 Way reference-list edits;
- 500 Relation member-list edits;
- 1,000 valid local creates (Node-heavy with dependent Ways/Relations);
- 1,000 deletes/restores/replacements exercising tombstones and index repair.

The exact deterministic selector belongs in the benchmark source and is
versioned. Every batch ends with semantic/index-integrity verification.

Measure:

- edit wall time;
- additional owned bytes;
- parent-index update cost;
- tombstone count;
- lazy baseline-journal bytes;
- revert cost for the same batch.

## Workload F — local ID remap

Create a deterministic local Node -> Way -> Relation dependency graph, then
apply server-style negative-to-positive ID/version mappings.

Measure:

- remap wall time;
- number of inbound references rewritten;
- primary/reverse index integrity;
- handle stability before/after remap.

The checksum must prove that no old negative reference remains when its mapping
was applied.

## Memory decision targets

These are architecture targets for the pinned Bremen workload, not claims about
all OSM data.

### Target 1 — material reduction versus equivalent baseline

With primary and required parent indexes included in **both** implementations,
the production candidate should use at most:

```text
75% of the final incremental RSS of the straightforward reference store
```

on the same fresh-process Bremen workload.

If a candidate cannot save at least 25% while retaining equivalent behavior,
its extra representation complexity needs a stronger measured justification.

### Target 2 — low-end city budget

The first production candidate should keep Bremen's final incremental RSS
(excluding the identical caller-owned PBF input buffer) at or below **512 MiB**.

A **384 MiB** result is the stretch target. These are engineering decision
budgets, not public API guarantees.

### Target 3 — construction overhead

For the direct PBF-to-store path in #64, peak incremental RSS excluding the
identical input buffer should be no more than **1.5x the final store
incremental RSS** on Bremen.

If the target is missed, measurements must identify whether temporary decode
storage, index construction or compaction is responsible before introducing a
new allocator/arena.

## Performance decision rules

- LDC release builds are the architecture-performance reference.
- DMD remains a correctness/development comparison.
- All integrity checks remain enabled.
- Dataset generation/query selection/checksums stay outside timed regions.
- Warm/cold cache state is reported.
- Use fresh processes for memory comparisons.
- No layout is selected from isolated `sizeof`, synthetic-only, or Node-only
  wins.
- A candidate that saves memory but materially regresses edit/navigation
  workloads must explain the tradeoff before adoption.
- C++-class performance remains the workspace goal; #62 does not require a new
  scientific benchmark framework.

## #62 decision gate

Before selecting a production layout, #62 must publish one table for Bremen
containing at least:

- final/peak incremental RSS;
- reference ratio;
- build wall time;
- Node/Way/Relation lookup;
- parent lookup;
- traversal;
- edit batch;
- remap workload;
- correctness checksum result.

Monaco or Liechtenstein is used for fast iteration; Bremen decides the layout.
Austria is reserved for later stress/direct-build qualification when practical.


## #62 selected representation

#62 selected the production compact layout recorded in ADR 0022:

- columnar fixed-width element fields;
- compact append-only pools for tags, Way children and Relation members;
- one shared interned string pool;
- separate open-addressed typed primary ID indexes;
- stable opaque slot/generation/store handles;
- deterministic non-GC ownership for the high-volume compact core;
- lazy owned baselines only for edited loaded elements.

The selected layout does **not** add a `mir.ndslice` dependency. The consumer
API remains semantic `OsmStore`; representation vocabulary stays internal.

On the pinned Bremen decision workload, the selected layout used 345,208 KiB
final incremental RSS versus 950,452 KiB for the equivalent straightforward
reference, a 63.680% reduction. Logical owned bytes including the identical
benchmark parent index fell from 693,270,944 to 316,034,245 (54.414%).

Primary typed-ID lookup was faster in all three element families. Full semantic
traversal and edit/revert were slower than the straightforward object graph;
the accepted trade-off is documented in ADR 0022. The 10,000-operation compact
edit batch remained 19.130 ms on the qualification runner.

The parent index used for this decision is benchmark-only and identical on both
sides. Production parent-index layout and incremental coherence remain #63.

The borrowed semantic ingest used to isolate retained-store RSS is
package-internal qualification machinery. Public production PBF-to-store
construction remains #64.
