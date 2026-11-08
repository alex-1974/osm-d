
# ADR 0033 — OSM history, authoritative refresh and conflict boundary

Status: accepted for M18
Date: 2026-11-08
Issues: #144, #145, #146, #147, #148

## Context

After M17, osm-d can read current and historical Editing API element responses,
but an editor or synchronization consumer still needs format-independent
semantics for:

- an OSM element's authoritative version history;
- refreshing a partial editable store from newer server state;
- distinguishing safe refresh from local-only work and concurrent changes;
- describing base/local/remote conflicts without embedding UI or merge policy.

These are OSM data semantics, not generic networking. They also are not editor
undo/redo history. The compact store already owns stable handles, lazy edit
baselines, primary indexes and reverse parent indexes; M18 must reuse those
contracts instead of creating a second state machine.

## Decision

### 1. OSM history is an owning version sequence outside OsmStore

'osm.history.ElementHistory!T' models one Node, Way or Relation identity across
authoritative OSM versions.

The public aliases are 'NodeHistory', 'WayHistory' and 'RelationHistory'. Their
entries are 'HistoricalNodeVersion', 'HistoricalWayVersion' and
'HistoricalRelationVersion', deliberately distinct from live 'Owned*' values.

Each retained version owns independently mutable child arrays. Immutable string
bytes may be shared. Historical Node location has an explicit presence flag:
current OSM API responses may represent a deleted Node as 'visible=false'
without lat/lon, and M18 preserves that absence instead of inventing (0,0).
Converting such a deleted/location-less version to a live 'OwnedNode' fails.

A history explicitly declares either:

- 'HistoryCoverage.complete': versions must start at 1 and be contiguous; or
- 'HistoryCoverage.partial': gaps are allowed and remain observable.

All entries must have the same positive OSM ID, a positive explicit version and
strictly increasing version numbers. Duplicate, reversed or otherwise
ambiguous version sequences fail rather than being sorted or repaired.

Visibility/deletion is preserved through ordinary OSM metadata:
'hasVisibility && !visible' is reported as a deleted historical version.
Unknown visibility remains distinct from visible.

History is deliberately not stored inside 'OsmStore'. The store represents the
current editable working set; durable server version sequences and editor
undo/redo are separate concerns.

### 2. M17 history reads project directly into M18 histories

'EditingApiClient.readNodeHistory', 'readWayHistory' and
'readRelationHistory' return the corresponding typed history model. The
post-v0.3 development surface no longer exposes raw 'Owned*[]' history
overloads, because those live-object types cannot faithfully represent every
historical response.

Specific-version operations likewise return the corresponding
'Historical*Version' value. Current-element operations continue to return live
'OwnedNode', 'OwnedWay' and 'OwnedRelation'.

For OSM /history responses, a contiguous sequence beginning at version 1 is
classified as 'HistoryCoverage.complete'. A valid strictly increasing sequence
with version gaps is preserved as 'HistoryCoverage.partial'; gaps can occur
when historical versions are not available to the caller. Duplicate,
out-of-order, mixed-identity or otherwise ambiguous sequences fail rather than
being sorted or repaired.

### 3. Conflict classification is three-way and transport-independent

'osm.model.conflict' compares explicit base B, local L and remote R states for
one typed OSM identity.

The result is 'ConflictReport'. It records:

- identity/presence/version facts;
- overall disposition;
- per-key tag changes;
- duplicate-tag evidence;
- Node coordinate changes;
- ordered Way-node-reference changes;
- ordered Relation-member/type/role changes.

The library does not produce a merged object and does not choose a winner.

An 'independentConcurrent' result means the library can prove that the observed
facets or sequence edit spans do not overlap. It still requires application
resolution. osm-d does not auto-merge merely because concurrent changes appear
independent.

### 4. Ordered-sequence classification is deliberately conservative

Way references and Relation members preserve order and duplicates.

For each side, M18 computes the one contiguous changed span relative to the
common base using common prefix/suffix boundaries. Two concurrent edits are
classified as independent only when their base spans are provably disjoint.

Multiple edits that collapse into one broad overlapping span, insertion at an
ambiguous boundary, or other complex cases are reported as
'overlappingOrComplex'. This can produce a conservative conflict but cannot
silently declare an unsafe merge.

### 5. Authoritative refresh consumes values, not transport

'reconcileAuthoritative' accepts an 'AuthoritativeBatch' of present or absent
Node/Way/Relation states. It performs no network access.

The caller may obtain those values from 'osm.api', replication, fixtures, or
another trusted authoritative source.

This keeps M18 independent of HTTP, OAuth, retry policy, scheduling and account
selection.

### 6. Reconciliation preserves local work

For each identity, M18 reconstructs base/local state from the store's existing
lazy edit baseline and current lifecycle state, then classifies it against the
remote state.

| Situation | M18 action |
| --- | --- |
| no local or remote change | unchanged |
| local-only edit/delete | keep local |
| clean object, newer remote | refresh |
| remote-only new object | insert |
| clean object, authoritative deletion | remove as authoritative fact |
| identical local/remote concurrent payload | accept remote and mark clean |
| provably independent concurrent changes | report/defer; do not merge |
| overlapping conflict/baseline mismatch | report conflict; do not mutate |

A conflicting object remains semantic-state equivalent to the local working
copy. There is no implicit remote-wins fallback.

### 7. Existing store indexes and lifecycle remain authoritative

M18 does not maintain parallel indexes.

Safe refreshes reuse the ordinary 'OsmStore.replace' machinery and then
acknowledge the remote value as the new clean baseline. This preserves the
existing stable handle while updating primary/parent-index contributions.

An authoritative deletion invalidates the deleted object's old handle, matching
the established confirmed-delete lifecycle. Its tombstone remains an
authoritative absence fact but has no edit baseline, so 'collectChanges' does
not upload that server-side deletion as a new local delete.

Local-only and conflicting objects keep their existing handle and edit
baseline.

### 8. Batch semantic failures are preflighted before mutation

'reconcileAuthoritative' validates the complete batch before applying the first
planned store change:

- authoritative state identity/version shape;
- duplicate identities within each element type;
- store-representable tags and positive authoritative references;
- base/local/remote classification.

If any such preflight fails, the store is unchanged.

After successful preflight, the planned store operations are expected to be
semantically infallible and are asserted. Normal process/resource failure such
as allocation failure follows D/runtime allocation semantics; M18 does not
clone an entire city-scale store merely to promise rollback after an
out-of-memory condition.

This is the same pragmatic boundary used by existing store acknowledgement
operations: data/contract errors are transactional; catastrophic resource
failure is not turned into an expensive shadow-store transaction.

### 9. Public consumer surface is focused

The M18 facade is 'import osm.sync;'.

It exposes history, state/conflict and authoritative reconciliation values.

'import osm;' remains focused on common semantic/PBF/store workflows.
Application presentation, conflict-resolution UI, undo/redo, automatic merge,
retry/backoff, background scheduling and persistent synchronization checkpoints
remain outside osm-d.

## Consequences

### Positive

- consumers get one format-independent synchronization vocabulary;
- M17 server history composes directly with the history model;
- local edits cannot be silently overwritten by refresh;
- reverse indexes remain coherent through existing store mutation code;
- conflict reporting is deterministic and suitable for UI, logging or policy
  implemented above the library;
- partial datasets remain valid: unresolved positive references may remain
  unloaded, while authoritative negative/local references are rejected.

### Trade-offs

- histories own full semantic versions and are not optimized as an archival
  compression format;
- complex ordered edits are intentionally classified conservatively;
- independent concurrent changes are not auto-merged;
- authoritative deletion invalidates the old handle;
- reconciliation applies the safe subset of a valid batch while separately
  reporting deferred/conflicting entries; it is not an all-conflicts-abort
  policy.

## Qualification

M18 qualification covers:

- complete and partial history sequences, gaps and deleted visibility;
- deleted Node history/specific-version responses without invented location;
- M17 /history and /{id}/{version} response projection;
- Node tag/coordinate conflicts;
- Way ordered-reference edits;
- Relation member/role conflicts;
- duplicate tag keys;
- identical concurrent edits;
- remote deletion versus clean/local-modified state;
- local deletion versus changed remote state;
- clean refresh and remote insertion in a partial dataset;
- Node/Way/Relation parent-index maintenance;
- batch preflight with no earlier partial mutation;
- external 'import osm.sync;' compilation on baseline DMD/LDC;
- pragmatic editor-scale conflict-classification and refresh timing evidence.

No live OSM mutation is required for this qualification.
