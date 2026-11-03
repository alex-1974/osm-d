# ADR 0021: compact editable store contract

- Status: Accepted
- Date: 2026-11-03
- Related: #46, #61, #62, #63, #64
- Supersedes: none

## Context

M6 needs a durable random-access OSM data layer for editor-scale consumers
without turning `osm-d` into a Dunia application model.

M4 established the durable semantic vocabulary and M5 established whole-object
edit/change semantics. The compact store must preserve those contracts while
using materially less memory than a straightforward object graph and while
supporting the lookup/navigation patterns required by an editor.

The storage layout itself is intentionally not decided here. Structure of
arrays, packed child pools, string interning, hash-table choices, and other
representation techniques belong to #62 and must be selected with city-scale
evidence.

## Decision

### Scope

The first compact store is an **in-memory, process-local, editable semantic
store**.

It owns all durable bytes and element state. It does not borrow PBF/XML input
buffers after insertion. It contains no GUI state, OSM account state, workset
UI state, rendering state, spatial index, network/cache policy, or Dunia-only
metadata.

Persistence, memory mapping, crash recovery and a stable on-disk format are
out of M6's first scope. The existing `store/mapped` namespace remains
reserved for later evidence-driven work.

### Semantic strength

The store represents editable/validated OSM semantic state, not arbitrary raw
codec input.

It therefore:

- preserves exact signed IDs and exact authoritative coordinates;
- preserves optional metadata presence and values;
- preserves tag order while requiring unique valid keys in validated state;
- preserves Way reference order and duplicates;
- preserves Relation member order, roles and legitimate duplicates;
- permits unresolved positive references required by partial extracts;
- rejects unresolved local/negative references in editable state;
- never silently repairs, drops, sorts or deduplicates data.

Raw/loss-preservation remains the responsibility of the raw/document codec
layers.

### Identity and lookup

Node, Way and Relation IDs remain separate namespaces.

Primary lookup by `(ElementType, OsmId)` must have expected O(1) behavior in
the production layout. Duplicate live IDs within one type are rejected.
ID zero is rejected for normal editable store state.

Numeric IDs are not stable handles: a local negative ID can be replaced by a
server-assigned positive ID after diff upload.

The store therefore exposes opaque value handles. A handle identifies an
element slot/generation independently of its current OSM ID. A handle:

- remains stable across content replacement and ID remapping;
- never aliases a different element after deletion;
- can report that its element is tombstoned;
- is invalidated only by an explicitly documented whole-store compaction/
  rebuild boundary.

Long-lived raw pointers or D references into store arrays are not public
handles.

### Borrowed access

Read views obtained from a handle are borrowed from the store. They remain
valid only until a structural mutation documented by the API. Consumers that
need independent lifetime copy into the owned semantic model.

The implementation may expose narrower invalidation guarantees when #62 proves
they are cheap, but it must not promise address stability that its containers
cannot maintain.

### Iteration order

Each element type has deterministic slot/insertion order.

- initial load preserves the codec's semantic delivery order for that type;
- replacing an element in place does not move it;
- ID remapping does not move it;
- normal live iteration skips tombstones;
- explicit compaction may change physical order and invalidates opaque handles
  according to the compaction contract.

OSM semantics never depend on cross-type iteration order.

### Editing and baseline state

The store distinguishes at least:

- clean loaded element;
- locally created element;
- modified existing element;
- deleted/tombstoned existing element.

The first edit of an existing clean element captures a baseline lazily
(copy-on-first-edit or an equivalent compact journal). The store does **not**
duplicate the complete loaded dataset merely to support editing.

This baseline exists to support:

- revert-to-baseline;
- removal of a dirty flag after a true semantic revert;
- complete-object modify construction;
- deletion/restore without losing authoritative version metadata.

A created element has no server baseline. Deleting a still-local created
element cancels the upload change rather than creating an impossible server
delete.

Undo stacks, command history and UI transactions are application concerns.
The store only guarantees coherent current/baseline/lifecycle state.

### ID remapping after upload

Applying a successful server ID mapping is an explicit store operation.

Remapping a local ID to a server ID must atomically update:

- the primary ID index;
- the element's own ID;
- every Way/Relation reference to that local ID;
- affected reverse/parent indexes;
- lifecycle/version metadata supplied by the authoritative server result.

The opaque handle remains stable.

The store never assumes server ID or version increments.

### Parent indexes

M6 requires reverse navigation without whole-store scans:

- Node ID -> parent Ways;
- Node/Way/Relation identity -> parent Relations.

Reverse indexes operate on typed identities, may contain keys whose positive
target object is absent from a partial dataset, and preserve enough parent
identity to update coherently after edits.

Index maintenance is part of the mutation transaction. A successful public
mutation cannot leave forward data and reverse indexes disagreeing.

### Deletion and tombstones

Deleting an existing element removes it from normal live ID lookup/iteration
and leaves a tombstone slot until explicit compaction. Its handle cannot be
reused for another element.

Incoming references from other live elements are **not** silently removed.
They remain visible as integrity/editing state for the caller to resolve.

Deleting a Way/Relation removes that element's outgoing contributions from
parent indexes. Deleting a referenced Node/Way/Relation does not erase incoming
references from its parents.

### Thread safety

The first store is **single-writer and externally synchronized**.

- Mutating operations are not concurrently callable.
- Read-only access may be concurrent only while no mutation/compaction occurs.
- No per-element locks or atomics are required in the normal store path.
- #64 may use worker-local construction/staging, but publication into the
  durable store must preserve the same single-writer semantic boundary.

A future synchronized wrapper can be added without embedding locking overhead
in every element access.

### Error and mutation atomicity

Public mutations validate all required preconditions before committing visible
state. On failure, element data, primary indexes, reverse indexes and lifecycle
state remain unchanged.

Errors are structured and identify the affected type/ID/handle where practical.
No mutator repairs invalid input implicitly.

### Layout freedom

This ADR deliberately does **not** require:

- AoS or SoA;
- `mir.ndslice`;
- one specific hash map;
- one allocation strategy;
- one string-pool design;
- fixed-width versus variable-width child pools.

Those are #62 decisions and require workload evidence.

## Consequences

- The store remains reusable outside Dunia.
- ID remapping does not force consumer handle replacement.
- Long-lived selection/reference state uses handles, not array addresses.
- Copy-on-first-edit limits baseline duplication to the edited subset.
- Parent navigation is a first-class store responsibility.
- Persistence can evolve separately without freezing a premature disk format.
- #62 can compare layouts against one semantic/API contract rather than change
  requirements to suit a favored representation.
