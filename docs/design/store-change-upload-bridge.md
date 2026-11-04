# Store change/upload bridge

Issue: #100  
Children: #96, #97, #98, #99  
Decision record: ADR 0025

## Purpose

The compact store already retains explicit lifecycle state and lazy baselines.
M9 connects that state to the existing format-neutral change model and back to
authoritative OSM diff-upload results.

This bridge belongs in osm-d because it is OSM edit semantics. It does not own
HTTP, OAuth, changeset creation/closing, retry policy, UI state or an editor
undo stack.

## Change materialization

`OsmStore.collectChanges` explicitly allocates and copies a durable
`OwnedChangeSequence`. The mapping is:

| Store state | Change |
| --- | --- |
| clean | omitted |
| created | create, complete current object |
| modified | modify, complete current object |
| deleted established object | identity-only delete using baseline metadata |
| created then deleted | omitted |

A delete after an unuploaded modify uses the captured pre-edit baseline
metadata. In particular, the authoritative version is not replaced by a local
payload edit.

No changeset ID is invented. The caller explicitly supplies it after
materialization, normally with `OwnedChangeSequence.setChangeset`.

## Ordering

The sequence is deterministic and suitable for the upload validator:

1. created Nodes;
2. created Ways;
3. created Relations in local-relation dependency order;
4. modified Nodes;
5. modified Ways;
6. modified Relations;
7. deleted Relations;
8. deleted Ways;
9. deleted Nodes.

Negative/local references must resolve to a currently created object. Created
Relations are topologically ordered by negative Relation dependencies.
A circular local Relation dependency cannot be represented by one API 0.6 diff
upload and fails with `StoreError.cyclicLocalDependency` rather than being
silently reordered into an invalid request.

Change extraction touches the sparse edit journals plus locally created slots;
it does not require scanning every loaded city element.

## Upload result model

`UploadResultEntry` is the format-neutral semantic form of one successful
API 0.6 diff-result row:

- create: negative `oldId`, positive `newId`, positive `newVersion`;
- modify: positive `oldId`, identical `newId`, positive `newVersion`;
- delete: positive `oldId`, no new ID/version.

`UploadResult` owns an array of these values. XML response parsing and HTTP
transport remain outside this model.

## Applying an authoritative result

`OsmStore.applyUploadResult(uploaded, result, status)` requires both the
server result and the exact semantic sequence that was sent.

This is deliberate. An upload may be in flight while the user continues
editing. Before any mutation, the store verifies that every uploaded object
still matches the current pending state, ignoring only the caller-assigned
changeset field. A newer local edit therefore produces
`StoreError.staleUploadState` instead of being incorrectly marked clean.

Result order is not significant. Entries are matched by element type and old
ID.

On success:

- create: local ID is remapped to the authoritative ID/version; inbound
  Way/Relation references and reverse indexes are rewritten; the handle stays
  stable;
- modify: authoritative version and the explicitly uploaded changeset are
  recorded, the lazy baseline is released, and the handle stays stable;
- delete: the pending baseline is released and the deleted object's old handle
  is invalidated.

The OSM diff result does not contain server timestamp/user metadata. osm-d does
not fabricate those values. A later server refresh may replace them.

## Failure atomicity

All semantic/result validation is completed before the first visible store
mutation. Mismatched counts, duplicate result identities, invalid result shape,
stale local state, changed payload, invalid change metadata and conflicting
create IDs fail without acknowledging any object.

As elsewhere in the store, resource exhaustion is not translated into a
recoverable semantic status after allocation has begun.

## Qualification

The durable tests cover:

- Node -> Way -> Relation local create dependencies;
- forward Relation dependency reordering;
- circular local Relation rejection;
- create-then-delete cancellation;
- modify-then-delete baseline/version preservation;
- osmChange write/read semantic round trip;
- upload-readiness validation;
- shuffled authoritative result order;
- local-ID remap and parent-index coherence;
- modify version acknowledgement;
- delete handle invalidation;
- stale-response failure before any partial acknowledgement.

The external consumer probes also compile the preferred v0.2 names and named
arguments under the supported fast DMD/LDC matrix.
