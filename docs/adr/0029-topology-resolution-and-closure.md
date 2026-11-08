# ADR 0029: ordered bounded OSM topology resolution and closure

- Status: Accepted
- Date: 2026-11-06
- Related: #131, #133
- References:
  - ADR 0021 compact editable store contract
  - ADR 0028 dataset/reference validity

## Context

Dataset/reference validation answers whether typed identities and references are
coherent under a complete or intentionally partial dataset contract. Consumers
also need to navigate those references without turning osm-d into a generic
geometry library or forcing every workflow to materialize complete objects.

Two backing models exist:

- `OsmStore`, which already owns typed primary and reverse indexes;
- `OwnedDataset`, which is a durable editable value model and deliberately
  carries no permanent hidden index.

OSM Relation graphs may contain duplicate members, self-reference, longer
cycles, missing positive references in partial extracts and hostile/deep
nesting.

## Decision

### Focused facade

Topology is exported through `import osm.topology;`.

It is not added to the curated `import osm;` root. This keeps graph traversal
and its explicit workspaces/limits discoverable without broadening the ordinary
semantic/PBF/store surface.

### Direct ordered resolution

Way Node references and Relation members resolve lazily in original source
order.

For `OsmStore`:

- live targets resolve to stable `OsmHandle` values;
- no new primary or reverse index is built.

For `OwnedDataset`:

- consumers explicitly build `OwnedDatasetIndex`;
- resolved targets are reported as typed array indices;
- the index contains primary ID lookup plus reverse parent edges;
- the index retains no dataset and materializes no complete OSM objects.

`OwnedDatasetIndex` must be rebuilt after changes to IDs, element ordering,
insert/remove operations, Way Node references or Relation members. Tag,
metadata and coordinate-only edits do not invalidate it.

### Resolution state is not validation

Resolution reports:

- resolved;
- unresolved positive/server reference;
- unresolved local/negative reference;
- zero reference;
- invalid member type.

Traversal does not silently repair, fetch or drop unresolved references.
`validateDataset` remains the authority for deciding whether those states are
permitted by the selected complete/partial dataset contract.

### Relation child closure

`walkRelationClosure` walks descendants depth-first.

- Relation-member occurrence order is preserved.
- Duplicate Relation members are emitted.
- A resolved Way member is expanded to its ordered Node-reference occurrences.
- Duplicate Way Node references are emitted.
- Every Relation occurrence is emitted, but one Relation identity is expanded
  at most once per traversal.
- Self-reference, mutual cycles and longer cycles therefore terminate without
  erasing the cyclic edge from the result stream.

The root Relation itself is not emitted as its own child.

### Parent closure

`walkParentClosure` emits distinct parent elements in deterministic
first-discovery order.

For `OsmStore`, existing parent indexes are reused directly.

For `OwnedDataset`, the reverse edges built by the explicit
`OwnedDatasetIndex` are reused. Duplicate raw reverse edges caused by
duplicate child references are deduplicated by the traversal workspace.

A parent closure may start from an unresolved positive identity; this is useful
for partial extracts whose loaded parents reference an omitted child.

### Bounded work and explicit workspace

Recursive/closure traversal requires caller-visible:

- `TopologyTraversalWorkspace`;
- `TopologyTraversalLimits`;
- `TopologyTraversalStatus`.

Limits bound maximum graph depth, emitted visits and Relation expansion.
Exhaustion is an explicit failure rather than silent truncation.

A non-zero visitor return is an intentional early stop. It is not an error, but
`completed` remains false.

The workspace is reusable but is not concurrently shareable.

### Borrowing and mutation

Store topology ranges/visits borrow the same store semantics as existing store
views. Structural `OsmStore` mutation during a traversal is not permitted.

OwnedDataset traversal borrows dataset arrays and relies on the supplied
`OwnedDatasetIndex` matching the current topology layout.

### Scope boundary

This topology layer does not own:

- complete-object materialization;
- multipolygon/area assembly;
- segment or polygon algorithms;
- CRS/projection/geodesy;
- spatial indexing;
- rendering;
- network retrieval of missing members.

Complete resolved objects and OSM-specific area assembly remain M16. Generic
geometry remains in the geometry libraries.

## Consequences

Consumers can navigate ordinary and cyclic OSM graphs without rebuilding
indexes or materializing a second object graph.

Partial-data absence remains visible rather than being confused with
corruption.

The store keeps one authoritative reverse-index implementation.

OwnedDataset users pay indexing cost only when they explicitly need indexed
random access or closure traversal.

Traversal cost is bounded by a consumer-selected contract suitable for hostile
or very deep Relation graphs.

## Alternatives rejected

### Recursively materialize complete objects

Rejected because it couples graph navigation to ownership/allocation and
duplicates the M16 complete-object layer.

### Treat Relations as a tree

Rejected because real OSM data is a graph and cycles must be handled safely.

### Rebuild reverse relationships for each query

Rejected for `OsmStore` because the store already maintains authoritative
reverse indexes. For `OwnedDataset`, reverse edges are built once in the
explicit reusable index.

### Silently skip unresolved references

Rejected because partial-data absence and broken local references are
semantically relevant to editors and validation.
