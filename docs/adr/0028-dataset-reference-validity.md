# ADR 0028: explicit complete and partial dataset reference validity

- Status: Accepted
- Date: 2026-11-05
- Related: #133, #130, #131
- References:
  - ADR 0006 layered validation
  - ADR 0021 compact editable store contract

## Context

osm-d already distinguishes wire validity, format structural validity, OSM
element validity, dataset/reference validity and uploadability.

The first three stages are codec/element concerns. Upload validation is stronger
again: it applies changeset IDs, versions, server capability limits, canonical
coordinate precision and request-local placeholder ordering.

What is missing is the dataset/reference stage itself.

OSM consumers routinely work with two legitimate shapes:

- a complete dataset, where every Way/Relation reference must resolve locally;
- an intentionally partial extract or API result, where positive server IDs may
  refer to objects outside the loaded subset.

An editable store also supports local negative IDs. Treating an unresolved
negative ID as merely "partial" would hide a broken local edit graph.

## Decision

### Add one explicit mode

Dataset validation exposes:

- `DatasetValidationMode.complete`;
- `DatasetValidationMode.partial`.

Complete mode requires every typed reference to resolve to a live target in the
validated dataset/store.

Partial mode permits an unresolved **positive** reference. It does not permit an
unresolved negative/local reference.

### Identity rules

Node, Way and Relation IDs remain separate namespaces.

Within one type:

- ID zero is invalid;
- duplicate element IDs are invalid;
- positive and negative non-zero IDs are representable dataset identities.

The same numeric ID may exist once in each different element type.

### Reference rules

For every Way node reference and Relation member:

- reference ID zero is invalid;
- the Relation member type must be Node, Way or Relation;
- an existing correctly typed live target is valid;
- a missing negative/local target is invalid in both modes;
- a missing positive target is invalid in complete mode and permitted in
  partial mode.

Relation self-reference and longer Relation cycles are not rejected merely
because they are cycles. Reference validity asks whether the typed identity
exists; recursive topology traversal must be cycle-safe separately under #131.

### Tombstones

The editable store retains tombstones after local deletion while removing them
from ordinary live lookup.

A reference from a live element to a target known to be tombstoned in the same
store is `deletedReference` in **both** modes. It is not treated as an allowed
partial-extract omission because the store knows the target was deliberately
deleted.

The validator builds temporary typed tombstone sets once per store validation
pass through a package-internal collector. This avoids repeated whole-slot scans
when a partial extract contains many unresolved positive references. No new
public tombstone-query API or permanent store index is added.

### Deterministic first issue

The validator reports the first deterministic issue rather than allocating a
diagnostic list.

For `OwnedDataset`, order is:

1. Node identities;
2. Way identities;
3. Relation identities;
4. Way references in array/order;
5. Relation members in array/order.

Store validation follows deterministic live Way/Relation range order and child
order.

The issue identifies the containing element, child index and typed target where
applicable.

### Keep upload validation separate

`validateDataset` does not check:

- changeset IDs;
- authoritative versions;
- upload create/modify/delete ID-sign policy;
- server capability limits;
- tag UTF-8/length/duplicate-key upload rules;
- canonical 1e-7-degree upload precision;
- geometry validity.

Those remain in the stronger `validateUploadChanges` layer or later focused
geometry validation.

## Consequences

A partial OSM extract is no longer forced to masquerade as either fully valid
or invalid.

Local broken references remain fail-closed even in partial mode.

M15 topology resolution can reuse the same typed-reference semantics without
changing what "partial" means.

The compact store does not gain another public index or query abstraction.

## Alternatives rejected

### Treat every missing reference as invalid

Rejected because partial OSM extracts and API responses are ordinary consumer
inputs.

### Treat every missing reference as allowed in partial mode

Rejected because unresolved local negative IDs would hide invalid edit graphs.

### Reject Relation cycles during reference validation

Rejected because cycle detection is a traversal concern; a cycle can consist
entirely of valid typed references.

### Fold this into upload validation

Rejected because dataset/reference validity is useful for non-upload consumers
and intentionally weaker than request/server uploadability.
