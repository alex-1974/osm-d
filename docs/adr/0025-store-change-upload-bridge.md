# ADR 0025: editable store change/upload bridge

- Status: Accepted
- Date: 2026-11-04
- Related: #100, #96, #97, #98, #99
- References:
  - OSM API 0.6 diff upload and diffResult semantics
  - ADR 0020 format-neutral change semantics
  - ADR 0021 compact editable store contract

## Context

The M6 store already records `clean`, `created`, `modified` and
`deleted` lifecycle state, preserves a lazy baseline for edited loaded
objects, remaps local IDs and maintains reverse indexes. The detailed M6
contract also requires complete change semantics to be constructible from that
state.

The M5 change model and osmChange codec are intentionally format-neutral above
the XML parser. The store therefore should not grow XML nodes, HTTP responses
or Dunia-specific upload state merely to connect editing with upload.

A second problem exists after a successful diff upload: an editor may continue
changing an object while the request is in flight. Applying a late server
response only by ID would risk marking newer local work clean.

## Decision

### Materialization

Add `OsmStore.collectChanges`. It materializes one owned change sequence from
pending lifecycle state and makes allocation explicit in the API name.

Create/modify use complete current object state. Established deletes use
identity-only deletion plus baseline metadata. A local create deleted before
upload disappears from the sequence.

No changeset ID is inferred. `OwnedChangeSequence.setChangeset` is an
explicit caller operation.

### Dependency order

Create entries are emitted Node -> Way -> Relation. Created Relations are
topologically ordered by negative Relation references. Modifies follow all
creates. Deletes use Relation -> Way -> Node order.

Unresolved negative references and local Relation cycles fail explicitly.

### Sparse edit work

Change extraction uses the existing lazy baseline maps plus sparse created-slot
journals. It is proportional to edit state rather than to every loaded element.

### Authoritative result

Add format-neutral `UploadResultEntry` / `UploadResult` values reflecting
the API 0.6 diff-result contract.

Add `OsmStore.applyUploadResult(uploaded, result, status)`. The uploaded
sequence is required as the optimistic local snapshot. Before mutation the
store verifies result shape, identity coverage, lifecycle state and current
semantic equality, excluding only the explicitly assigned changeset field.

Result order is not part of the store contract.

### Acknowledgement effects

Created and modified objects keep their stable handles. Creates reuse the
existing authoritative ID-remap mechanism so forward/reverse indexes are
updated in one store mutation. Modifies receive the server-returned version and
drop their baseline.

Confirmed deletions remain tombstoned but their former handle generation is
invalidated; they are no longer revertible local edits.

The server response does not provide timestamp/user metadata, so these values
are not invented.

## Consequences

The reusable osm-d layer now spans:

`editable store -> format-neutral changes -> osmChange/validation -> authoritative result -> editable store`

without owning network/account policy.

A caller can safely reject a delayed result when the corresponding object has
changed since the upload snapshot.

The sparse created-slot journals add memory proportional to locally created
objects, not the loaded dataset.

Circular local Relation placeholders remain a visible upload limitation rather
than being hidden by arbitrary ordering.

## Alternatives rejected

### Return XML/osmChange directly from OsmStore

Rejected because XML is an interchange format, not the store model, and would
couple editing state to one codec.

### Apply result only by old ID

Rejected because a delayed response could erase newer local edit state.

### Scan the complete store on every change collection

Rejected because edit/export work should scale with the edited subset for
city-scale consumers.

### Keep deleted handles valid after server acknowledgement

Rejected because `revert` would then appear able to resurrect an object that
the server has already deleted. Surviving object handles remain stable; a
confirmed deleted identity does not survive.
