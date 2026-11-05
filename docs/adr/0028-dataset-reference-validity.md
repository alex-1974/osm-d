# ADR 0028: complete and partial dataset reference validity

- Status: Accepted
- Date: 2026-11-05
- Related: #130, #131, #132, #133
- Supersedes: none

## Context

ADR 0006 defines dataset/reference validity as a separate stage between
per-element validity and operation-specific validity such as uploadability.
ADR 0021 already permits unresolved positive references in the editable store
because legitimate extracts and API results can be partial, while rejecting
unresolved local/negative references during editing.

M15 needs one consumer-visible contract that makes those semantics explicit for
both OwnedDataset and OsmStore.

A boolean "valid dataset" is insufficient. The same positive missing Node may
mean:

- corruption in a dataset the caller declares complete; or
- a legitimate object outside a deliberately partial extract.

At the same time, partiality must not become an escape hatch for internally
inconsistent local edits.

## Decision

### Two explicit modes

Dataset reference validation uses DatasetReferenceMode:

- complete — every reference must resolve to a live target;
- partial — an absent positive/server reference is permitted and counted as
  unresolved.

complete is the enum .init value so default construction is fail-closed.

The mode is a caller assertion about the intended dataset coverage. osm-d does
not infer completeness from the codec, filename, bounding box or source URL.

### Reference classification

For every Way node reference and Relation member, validation applies this
order:

| Reference state | complete | partial |
| --- | --- | --- |
| target exists and is live | resolved | resolved |
| positive target absent/unknown | error: missingReference | accepted unresolved |
| local/negative target absent | error: unresolvedLocalReference | error: unresolvedLocalReference |
| target ID is zero | error: zeroReference | error: zeroReference |
| target is a known OsmStore tombstone | error: deletedReference | error: deletedReference |
| Relation member type is outside ElementType | error: invalidReferenceType | error: invalidReferenceType |

A known tombstone is deliberately different from an unknown positive identity:
the store knows that this target existed locally and was deleted. Partial
coverage therefore cannot reclassify that local dangling reference as an
external extract hole.

OwnedDataset has no lifecycle/tombstone representation, so deletedReference is
specific to the store-backed validation path.

### OSM ordering and cycles

The following are valid reference structure and are not repaired or rejected:

- repeated Node IDs in a Way;
- repeated Relation members;
- Relation self-reference;
- mutual or longer Relation cycles.

Validation checks whether typed targets exist. It does not recursively expand
Relations, so cycles cannot cause unbounded validation work. #131 owns
cycle-safe recursive traversal.

### Dataset identity

OwnedDataset intentionally has no persistent identity index. Before validating
its references, the validator builds a temporary typed identity index and
rejects:

- element ID zero;
- duplicate element IDs inside one ElementType namespace.

Equal numeric IDs across Node, Way and Relation remain independent and valid.

OsmStore already enforces nonzero unique live identities. Its validator reuses
the existing primary indexes.

### Diagnostics and ordering

validateDatasetReferences returns:

- DatasetReferenceSummary — element/reference counts and resolved/unresolved/
  invalid reference counts;
- DatasetReferenceIssue — the first deterministic failure.

Issue vocabulary intentionally follows UploadValidationIssue where possible:
elementType/elementId identify the source object, childIndex identifies the Way
reference or Relation member, and referenceType/referenceId identify the
target.

Deterministic order is:

1. OwnedDataset identity preflight: Nodes, Ways, Relations, each in array order;
2. live Ways in dataset/store order, references in their exact order;
3. live Relations in dataset/store order, members in their exact order.

A successful partial validation may have unresolvedReferences > 0 and
referentiallyComplete == false. The function still returns true because the
dataset satisfies the chosen partial policy.

### Allocation and early exit

OwnedDataset validation may allocate a temporary identity index proportional to
the number of elements. This is explicit and reflects the fact that
OwnedDataset is durable semantic storage, not an indexed query structure.

OsmStore validation reuses live primary indexes. It allocates only a temporary
typed set proportional to the number of tombstones so deleted targets remain
distinguishable from unknown external identities. With no tombstones, no
per-reference result collection is materialized.

Validation exits immediately on the first policy-invalid identity/reference.
Partial-mode positive absences are counted rather than stored in an unbounded
issue array. #131 resolution APIs provide per-object unresolved-reference
inspection when a consumer needs the actual sequence.

### Relationship to upload validation

Dataset reference validity does not replace validateUploadChanges.

Dataset validation answers whether references are coherent for the declared
dataset coverage. Upload validation additionally owns operation-specific rules
such as changeset/version requirements, create placeholder ordering, server
limits, XML representability and complete-object modification semantics.

A dataset may therefore satisfy partial reference validation while not being
uploadable.

## Consequences

- consumers can distinguish "partial but coherent" from "complete and
  referentially complete" and from "internally inconsistent";
- local missing IDs and tombstones cannot be hidden by selecting partial mode;
- duplicate/order/cycle OSM semantics are preserved exactly;
- Store validation scales from existing indexes rather than rebuilding a live
  identity map;
- OwnedDataset remains lightweight and index-free until a consumer explicitly
  requests dataset validation/resolution;
- #131 can build ordered resolution and recursive traversal on the same
  reference-state vocabulary without introducing geometry policy.
