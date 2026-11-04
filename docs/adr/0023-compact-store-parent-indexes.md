# ADR 0023: incremental parent indexes for the editable store

- Status: Accepted
- Date: 2026-11-04
- Related: #46, #63, #64
- Supersedes: none

## Context

ADR 0021 requires reverse navigation without whole-store scans and requires
mutations to keep forward and reverse state coherent. ADR 0022 selected the
compact element layout and deliberately left the production parent-index
representation to #63.

An editable OSM store needs two reverse relations:

- Node ID -> parent Ways;
- typed Node/Way/Relation ID -> parent Relations.

The same parent may contain the same child more than once. Those duplicate
forward references are real OSM semantics and must remain in the Way/Relation
child pools, but editor navigation normally asks for distinct parent objects.

A static packed index gives fast contiguous lookup but requires a full rebuild
after changes. That is a poor default for an editable store.

## Decision

### Public semantics

`OsmStore.parentWays(nodeId)` returns distinct live parent Ways.

`OsmStore.parentRelations(type, id)` returns distinct live parent Relations
for one typed child identity. Equal numeric Node, Way and Relation IDs remain
separate namespaces.

The referenced child need not itself be present. Positive unresolved
references from partial extracts can therefore still have reverse navigation.

Returned parent ranges are borrowed store views and follow the same structural
mutation invalidation rule as the other store ranges.

### Representation

The store keeps four compact reverse indexes:

- Node -> Way;
- Node -> Relation;
- Way -> Relation;
- Relation -> Relation.

Each index uses an open-addressed key table from OSM ID to a linked chain of
compact parent edges. One edge represents one distinct parent for one key.
Duplicate forward references therefore do not multiply the reverse result.

The edge stores only parent slot, active state and next-link. Parent slot and
active state share one 32-bit field; the high bit is internal state and leaves
31 bits for a parent slot. This is an implementation limit far above the
practical in-memory store capacity and is not exposed in the public API.

### Mutation coherence

Forward and reverse data are updated in the same single-writer store mutation.

- adding a Way/Relation installs its outgoing parent contributions;
- replacing a Way/Relation disables the old current contributions before
  installing the new current contributions;
- deleting a Way/Relation disables its outgoing contributions;
- restoring the tombstone reactivates its current contributions;
- replacing/reverting keeps duplicate forward references exact while reverse
  results remain distinct.

Deleting a referenced child does not remove incoming parent edges, in
accordance with ADR 0021.

### Authoritative ID remapping

`OsmStore.remapId` is the public server-ID mapping operation.

It accepts only a live element with a negative local ID, a positive unused
server ID, and a positive authoritative version. It:

- installs the new primary key;
- rewrites every current Way/Relation occurrence of the local ID;
- moves the affected reverse-index keys;
- updates the element ID/version/lifecycle;
- removes the old primary key;
- preserves the `OsmHandle`.

Current forward state held by tombstoned parents is rewritten as well. Such
parents remain absent from normal parent navigation until restored.

Validation failures are checked before visible mutation. Allocation failure is
an exceptional resource failure rather than a reported semantic validation
failure.

### No global rebuild on edits

The production store does not rebuild reverse indexes after an edit batch.
The benchmark's static packed index remains only the straightforward reference
used to measure the trade-off.

## Bremen qualification

Corpus:

- Geofabrik Bremen snapshot 2026-09-01;
- SHA-256
  `52bc46f09ce1f1198b95de308aba10c1b59108c9fdbb827fea305f7316b4ea0e`;
- 1,662,874 Nodes;
- 328,626 Ways;
- 5,985 Relations;
- LDC 1.41.0, Ubuntu 24.04 hosted runner, release/allAtOnce.

The reference uses a static packed distinct-parent index. The compact candidate
uses the production incremental indexes.

| Metric | Static reference | Production compact |
| --- | ---: | ---: |
| Parent-index logical bytes | 78,577,608 | 73,415,112 |
| Node -> Way lookup, p50 / 250k | 31.746 ms | 64.680 ms |
| typed -> Relation lookup, p50 / 100k | 2.952 ms | 3.461 ms |
| 10,000 edit batch | 5.509 ms | 29.210 ms |
| required full parent rebuild after edits | 396.032 ms | **0 ms** |
| final incremental RSS | 948,460 KiB | 351,324 KiB |
| total logical owned bytes | 691,378,472 | 308,976,077 |

The production linked index is slower for pure read-only Node-parent lookup than
the static contiguous reference. The trade-off is accepted because:

- the production representation is smaller;
- 250,000 Node-parent queries still complete in about 65 ms on the hosted
  runner;
- Relation-parent lookup remains close to the packed reference;
- a representative 10,000-operation editor batch keeps indexes coherent in
  about 29 ms;
- the static reference needs about 396 ms afterward to regain coherent reverse
  navigation.

For an editable store, avoiding whole-store rebuilds is the controlling
requirement.

All semantic, edit, revert, remap and production-parent query checksums passed
the city-scale qualification.

## Consequences

- editor-relevant parent navigation is expected O(1) to the parent-chain head
  plus result traversal;
- no whole-store scan or reverse-index rebuild is required after normal edits;
- duplicate OSM references remain exact in forward storage without duplicating
  parent-navigation results;
- unresolved positive child identities remain navigable;
- ID remapping is now a complete public store operation rather than a
  qualification-only kernel;
- #64 can construct a fully indexed durable store directly during PBF decode.
