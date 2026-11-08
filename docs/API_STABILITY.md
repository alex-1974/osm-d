# Public API and compatibility policy

> **v0.3.x contract.** This document defines the supported source-level
> compatibility surface for the osm-d v0.3 release line. Earlier release tags
> keep the immutable contracts that applied to those published states.

## Release line

The current supported release line is **v0.3.x**.

osm-d remains pre-1.0. v0.3.0 adds focused Editing API response/capability
facades and deliberately removes one misleading v0.2 compatibility property.
Patch releases within v0.3.x preserve this supported source contract unless a
security or correctness defect makes preservation impossible.

The release compiler floor is D frontend **2.111** with DUB **1.40.0**.
The qualified release matrix is:

- DMD 2.111.0, 2.112.1 and 2.113.0;
- LDC 1.41.0, 1.42.0 and 1.43.0;
- Ubuntu 24.04 x86_64.

Other operating systems and architectures may work, but v0.3.0 makes no
release-qualified portability claim for them.

## Compatibility promise

Within v0.3.x, patch releases do not deliberately remove or rename supported
symbols, change parameter order or supported parameter names, weaken
ownership/lifetime contracts, change documented failure semantics, or narrow
legal input solely for convenience.

The compatibility promise is source-level. There is no binary ABI guarantee
between D compiler versions or osm-d releases.

For supported ordinary functions and methods, parameter names are part of the
source contract because D named arguments can depend on them. Representative
named-argument calls are compiled by the release consumer probe.

A future v0.4.0 may contain deliberate pre-1.0 breaking changes. Such changes
must be documented and accompanied by migration guidance where practical.

## Preferred entry points

The supported high-level facades are:

- `import osm;` — common OSM identity/semantic values, owned values, borrowed
  PBF traversal and the editable store;
- `import osm.pbf;` — PBF-specific preservation/document writing, parallel
  summary decoding and PBF semantic comparison;
- `import osm.store;` — editable store and store/change reconciliation;
- `import osm.compare;` — serialization-independent OSM/change comparison;
- `import osm.xml;` — ordinary OSM XML;
- `import osm.osmchange;` — osmChange 0.6;
- `import osm.validate;` — dataset/reference and upload-readiness validation;
- `import osm.topology;` — ordered OSM reference resolution and bounded
  child/parent closure traversal;
- `import osm.complete;` — borrowed complete Way/Relation projections,
  direct completeness, exact OSM-native bounds and closed-Way identity;
- `import osm.area;` — owning OSM closed-Way/multipolygon ring assembly
  with explicit roles, provenance and partial/ambiguous/invalid diagnostics;
- `import osm.upload;` — bounded OSM API diffResult response parsing;
- `import osm.capabilities;` — Editing API capability discovery projected
  into upload-validation policy.

Low-level protobuf/wire, XML parser internals, validation implementation
modules and compact-store representation modules are not part of this
compatibility surface.

### Post-v0.3 development surface

The `develop` line after the v0.3.x freeze adds `import osm.api;` as the
focused OSM Editing API 0.6 protocol facade. It is not retroactively part of the
published v0.3.x compatibility promise.

The facade exposes `EditingApiClient`, explicit `EditingApiServer`,
`EditingApiStatus`, permission values and the owned OSM/Changeset/change values
needed by its operations. The client depends only on the generic
`transport.exchange.HttpExchange` seam; it does not expose or depend on a
concrete curl backend.

Authorization is request-scoped. Server configuration and the injected exchange
may be retained by the client; supplied Authorization header values are not.
Successful returned OSM values are owning semantic values. Non-success HTTP
responses preserve the exact status, an OSM-oriented classification where
known, and a bounded owned diagnostic prefix.

M18 additionally adds the focused `import osm.sync;` development facade. It
is likewise not retroactively part of the published v0.3.x compatibility
promise. The facade exposes:

- typed owning Node/Way/Relation authoritative histories with explicit complete
  versus partial coverage;
- explicit present/absent base/local/remote element states and deterministic
  `ConflictReport` classification;
- transport-independent `AuthoritativeBatch` /
  `reconcileAuthoritative` store synchronization.

The synchronization facade reports facts and conservative conflict boundaries;
it does not expose editor undo/redo, a merged-object result, automatic
conflict-resolution policy, networking or credential state. Successful clean
refresh preserves existing live handles; authoritative deletion invalidates
the old handle. Batch data/contract failures are preflighted before mutation.

The M17 `EditingApiClient` historical reads use the M18 historical values:
specific-version calls return `Historical*Version`, and /history calls return
typed histories. Current-element calls continue to return live `Owned*`
values. Historical Node location remains explicitly optional so a deleted
`visible=false` response without lat/lon is never normalized to fake
coordinates. Contiguous histories from version 1 are marked complete; valid
gapped sequences are retained as partial.

## Curated package root

`import osm;` intentionally exports:

- identity/semantic leaves: `OsmId`, `ElementType`, `LocationView`,
  `MetadataView`, `TagView`, `NodeRefView`, `RelationMemberView`;
- borrowed semantic PBF elements: `NodeView`, `WayView`, `RelationView`;
- owned semantic values: `OwnedBytes`, `OwnedTag`, `OwnedMetadata`,
  `OwnedNodeRef`, `OwnedRelationMember`, `OwnedNode`, `OwnedWay`,
  `OwnedRelation`, `OwnedDataset`, `ownBytes`;
- change/upload values: `ChangeAction`, `ChangeObjectState`,
  `OwnedChangeEntry`, `OwnedChangeSequence`, `UploadResultEffect`,
  `UploadResultEntry`, `UploadResult`;
- editable store: `OsmStore`, `OsmHandle`, store views/ranges/status and
  counts/memory values, primary lookup, parent navigation, edit lifecycle,
  `collectChanges`, `applyUploadResult`, `PbfStoreReadStatus`,
  `PbfSourceStoreReadStatus` and `readPbfStore`;
- ordinary borrowed PBF reading: `PbfReader`, `PbfReaderWorkspace`,
  element-specific iterables, `PbfReadSummary`, `PbfReadStatus`,
  `PbfSourceReadStatus`, `PbfReadError`, `PbfReadResult`,
  `PbfSourceReadResult`, `readPbf`,
  `pbfNodes`/`pbfWays`/`pbfRelations`, and `where!`.

Loss-aware PBF documents/writing and parallel-summary facilities deliberately
live in `osm.pbf` rather than the root.

The ordinary PBF reader and direct store builder also accept
`transport-d.ByteSource`. This is a byte-resource boundary only: osm-d owns
PBF framing/interpretation while transport-d owns filesystem, memory and HTTP
access. Loss-aware `PbfDocument` reading remains whole-buffer because its raw
preservation contract intentionally retains original encoded bytes.

The v0.3 Editing API codecs deliberately remain focused imports:
`osm.upload` parses successful diff-upload responses and `osm.capabilities`
projects current server validation policy. Neither is re-exported from
`import osm;`.

## Supported focused PBF facade

`import osm.pbf;` supports:

- the ordinary PBF reader family also reachable from `osm`;
- `PbfParallelReader` and `PbfParallelReadOptions`;
- `PbfRawFile`, `PbfPreservation`, `PbfPreservationReason`;
- `PbfDocument`, `PbfHeader`, `PbfHeaderBBox`, `readPbfDocument`;
- `PbfWriter`, `PbfWriteOptions`, `PbfWriteStatus`, `PbfWriteError`;
- PBF-specific semantic/raw comparison helpers.

Serialization-independent `sameOsmSemantics` and `sameChangeSemantics`
belong to `osm.compare`.

## Supported direct-import modules

The following direct imports are supported on v0.3.x:

- `osm`;
- `osm.pbf`;
- `osm.store`;
- `osm.compare`;
- `osm.xml`;
- `osm.osmchange`;
- `osm.validate`;
- `osm.upload`;
- `osm.capabilities`;
- `osm.model.owned`;
- `osm.model.change`;
- `osm.model.compare`;
- `osm.raw.pbf`;
- `osm.view.element`;
- `osm.view.location`;
- `osm.view.metadata`;
- `osm.view.tag`;
- `osm.view.node_ref`;
- `osm.view.relation_member`;
- `osm.view.way_node` as a migration compatibility import;
- `osm.io.pbf.reader`;
- `osm.io.pbf.parallel_reader`;
- `osm.io.pbf.document`;
- `osm.io.pbf.document_reader`;
- `osm.io.pbf.writer`.

The high-level XML, osmChange, upload-validation, upload-result and capability
facades are the supported entry points for those families. Their underlying
`osm.io.xml.*`, `osm.io.osmchange.*`, `osm.io.upload.*`,
`osm.io.capabilities.*` and `osm.validation.*` modules are implementation
organization, not an additional compatibility promise.

Other `osm.io.pbf.*`, `osm.wire.*`, `osm.util.*`,
`osm.store.compact.*` and `osm.store.mapped.*` modules are not supported
direct-import compatibility surfaces even if D makes declarations technically
importable.

## Earlier-line migration compatibility

v0.2 uses Node-reference terminology because a Way stores references to Nodes,
not embedded Node objects:

- `WayNodeView` -> `NodeRefView`;
- `OwnedWayNode` -> `OwnedNodeRef`;
- store Way-node leaf values -> `NodeRefView`.

The direct module `osm.view.way_node`, alias `WayNodeView`, and alias
`OwnedWayNode` remain available during v0.3.x migration. They are not
re-exported from the preferred package root.

PBF-specialized document/writer/parallel facilities that were root exports in
v0.1 are reached through `osm.pbf` in v0.2. Generic comparison helpers are
reached through `osm.compare`.

See `API_V0_2.md` for the v0.1 -> v0.2 migration and `API_V0_3.md` for
the v0.2 -> v0.3 migration.

The only deliberate v0.2.x source break in v0.3.0 is removal of
`UploadResultEntry.action`, which v0.2.1 already documented as an ambiguous
legacy shape guess. Use request-aware `effectFor` instead.

## Editable store and upload reconciliation

`OsmStore` owns inserted semantics and retains explicit edit lifecycle state.
`OsmHandle` is a stable store-local logical identity, not an address or OSM
ID.

`collectChanges` explicitly materializes current pending edits as an owned,
format-neutral `OwnedChangeSequence`. It does not invent a changeset ID.
`OwnedChangeSequence.setChangeset` is the explicit upload-preparation step.

Create ordering is dependency-safe for local Node/Way/Relation references.
Unresolved local references and circular local Relation dependencies fail
explicitly rather than producing an invalid upload sequence.

`applyUploadResult` requires both the exact uploaded semantic sequence and an
authoritative `UploadResult`. Before visible mutation it verifies that current
pending state still matches the uploaded snapshot, so a delayed server response
cannot silently acknowledge newer local work.

Successful create/modify acknowledgements preserve surviving handles. Create
remaps local IDs and inbound Way/Relation references through current parent
indexes. Confirmed deletion invalidates the deleted object's former handle.

OSM diffResult field shape is not a complete operation discriminator.
Conditional `delete if-unused` may return new ID/version when the server
retains the object; placeholder reuse may also repeat type+oldId in a general
result. `UploadResultEntry.effectFor` uses the exact uploaded entry as request
context. A retained store deletion restores its pre-edit baseline as clean;
an already-deleted acknowledgement finalizes the local tombstone.

v0.3 removes the legacy context-free `UploadResultEntry.action` shape guess.
Consumers classify result effects only with
`UploadResultEntry.effectFor(uploadedEntry, effect)`, because raw diffResult
shape is not sufficient request context.

The diff result does not carry complete server timestamp/user metadata; osm-d
does not fabricate those fields.

Network upload transport, OAuth/account state and changeset creation/closing
remain outside osm-d.

That sentence describes the released v0.3.x contract. For post-v0.3 development,
ADR 0032 accepts a broader OSM protocol boundary: osm-d will own OSM
method/path/media/status semantics and changeset protocol operations over an
injected generic transport. This does not retroactively add that client to the
frozen v0.3.x API; concrete public protocol-client symbols remain unfrozen until
M17 #141 is implemented and qualified.

M17 #140 adds the post-v0.3 focused `osm.changeset` facade. Its semantic model
separates server-returned `OwnedChangeset` state from the tag-only
`ChangesetTagRequest` create/update body. These symbols are post-v0.3
development API and do not alter the frozen v0.3.x surface.

## Ownership and lifetime

Borrowed PBF views are valid only for the documented synchronous callback or
foreach body and while their source input/workspace remains valid.
`NodeView` is deliberately non-copyable. Borrowed tag/member/reference ranges
may be copied as cursors but do not become owners of their backing data.

The owned semantic model owns durable child arrays/byte strings according to
normal D value/array semantics; `deepCopy` creates independently mutable child
arrays where provided.

Store semantic views and ranges borrow from store-managed storage and are
invalidated by structural mutation as documented. Stable `OsmHandle` values
survive replacement/revert and authoritative ID remap for surviving objects;
a server-confirmed deleted object invalidates its former handle.

`readPbfStore` borrows encoded PBF bytes only for the call. On success the
returned store no longer depends on the input bytes.

XML, osmChange, diffResult and capability readers/writers use transport-d
`ByteSource`/`ByteSink` contracts where applicable. osm-d does not create a
competing filesystem/network abstraction.

## Dataset/reference validation contract

The focused `osm.validate` facade exposes
`DatasetValidationMode.complete|partial`, `DatasetValidationIssue` and
`validateDataset` for both `OwnedDataset` and `OsmStore`.

Complete mode requires every typed Way/Relation reference to resolve locally.
Partial mode admits only unresolved positive/server references; unresolved
negative/local references and zero references remain invalid. Relation cycles
are representable and are not rejected at this layer.

Store tombstones are known local state: a live reference to a tombstoned target
fails as `deletedReference` even in partial mode.

This contract is deliberately weaker than `validateUploadChanges`. It does
not infer changeset/version policy, target-server limits, upload coordinate
precision or geometry validity.

## Topology resolution and traversal contract

The focused `osm.topology` facade owns OSM identity/reference graph
navigation.

Direct resolution preserves Way-node and Relation-member order and duplicates.
Store targets resolve to stable `OsmHandle` values. `OwnedDataset` uses an
explicit caller-built `OwnedDatasetIndex` and reports target array indices.

`OwnedDatasetIndex` contains typed primary lookup plus reverse parent edges.
It must be rebuilt after changes to IDs, element order, insert/remove operations,
Way Node references or Relation members. Tag, metadata and coordinate-only edits
do not invalidate it.

`walkRelationClosure` emits descendant edges depth-first, expands resolved Way
members to ordered Node references and expands each Relation identity at most
once. Relation occurrences themselves are still emitted, so cycles remain
observable without causing recursion loops.

`walkParentClosure` emits distinct parent elements in deterministic
first-discovery order. `OsmStore` reuses its maintained reverse indexes;
`OwnedDataset` reuses the reverse edges in its explicit index.

Recursive traversal requires `TopologyTraversalWorkspace`,
`TopologyTraversalLimits` and `TopologyTraversalStatus`. Depth, visit and
Relation bounds fail explicitly. A visitor-requested early stop is non-error
partial completion.

Unresolved references are reported, not repaired. `validateDataset` remains
the authority for complete/partial integrity. Structural store mutation during
borrowed topology traversal is outside the contract.

Complete-object materialization and area/multipolygon assembly are not part of
this M15 surface.

## Complete-object contract

The focused `osm.complete` facade enriches M15 reference resolution with
resolved semantic child objects.

For `OsmStore`, complete projections borrow existing store views and indexes.
Structural store mutation invalidates outstanding projections; consumers must
re-borrow afterwards.

For `OwnedDataset`, complete projections borrow dataset arrays and reuse a
caller-built `OwnedDatasetIndex`. The index invalidation rules from
`osm.topology` remain unchanged.

Direct resolution:

- preserves Way Node and Relation member order and duplicates;
- performs no network fetch or repair;
- exposes missing/invalid child states explicitly;
- allocates no second complete-object graph.

`CompleteObjectState` distinguishes `complete`, `partial` and `invalid`
after direct-child inspection. Store tombstones are not exposed as live
resolved targets; `validateDataset` remains the authority for distinguishing
known deletion from ordinary external omission.

`LocationBounds` and `locationBounds` preserve exact signed nanodegrees and
perform no projection, dateline reinterpretation or implicit floating-point
conversion. `isClosedWay` is the identity-only first/last-Node test and does
not imply polygon validity.

The package has no direct `geo-d` dependency. Geometry conversion remains an
explicit consumer boundary.

## OSM area assembly contract

The focused `osm.area` facade owns OSM-specific ring assembly, not generic
polygon computation.

`assembleClosedWayArea` structurally assembles a caller-selected closed Way.
It does not infer area semantics from the complete OSM tagging universe.

`assembleMultipolygon` requires a `type=multipolygon` Relation whose
supported geometry members are Ways with exact `outer` or `inner` roles.
Empty/unknown roles are not guessed. Node and nested Relation members are
reported explicitly as unsupported.

Open Way members are joined by exact endpoint Node ID. Relation member order is
not required to be ring order; source Way direction may be reversed in the
result without mutating source. A multiply-connectable endpoint is
`ambiguous`; no candidate is selected by hash order, coordinates or hidden
heuristics.

The owning `AreaAssemblyResult` retains assembled `AreaRing` values,
diagnostic `AreaOpenChain` values, detailed `AreaAssemblyIssue` entries and
source Way/member provenance. Resolved `LocationView` nanodegrees are copied
exactly.

`AreaAssemblyState` distinguishes `complete`, `partial`, `ambiguous`
and `invalid`. Missing positive/server references are partial. Invalid local,
zero or unsupported structure is not silently downgraded to partial data.

Ring identity may still assemble when a referenced Node object is omitted:
Node IDs remain available while `locationsComplete` becomes false.

No claim is made about ring simplicity, containment, orientation or polygon
validity. No direct `geo-d` dependency is introduced.

## Failure and `.init` contract

Fallible public operations use explicit success/status channels rather than
silently repairing input.

Important meanings include:

- read/write/store status structs, `DatasetValidationIssue.init` and
  `UploadValidationIssue.init`: success / no error;
- `PbfReaderWorkspace.init`: valid empty reusable workspace;
- writer/reader option structs: documented usable defaults;
- `LocationView.init`: exact coordinate origin;
- `OsmHandle.init`: invalid handle;
- `OwnedDataset.init`, `OwnedChangeSequence.init`, `UploadResult.init`:
  valid empty carriers;
- `AreaAssemblyResult.init`: valid empty/not-yet-assembled carrier with
  `AreaAssemblyState.notAssembled`; `AreaRingRole.none` means no accepted
  outer/inner role;
- `UploadResultEntry.init`: invalid diff-result entry because old ID is zero;
- `UploadResultDocument.init` and `EditingApiCapabilitiesDocument.init`:
  empty carrier/default projection values, not successful parsed documents;
- owned element structs at `.init`: structurally representable carriers, not
  an assertion that ID zero is valid editable/upload state.

For D `out` parameters, the destination is initialized to `.init` on entry.
Transactional whole-document/store/reconciliation APIs document output/store
state after failure. Streaming callbacks already delivered before a later
XML/osmChange failure are not rolled back.

## Safety and attributes

The supported high-level API is designed for ordinary `@safe` use.
`@safe`, `nothrow`, `@nogc`, DIP1000 and named-argument claims are
contracts only where present and are exercised by compile tests.

Narrow `@trusted` boundaries remain implementation details with explicit
safety arguments, including parallel reader orchestration, parser machinery
and the synchronous direct-PBF-store adapter. They do not enlarge the public
compatibility surface.

## Exact bytes and codec boundaries

Tag keys/values, usernames and relation roles preserve exact bytes. v0.3 does
not invent an osm-specific text wrapper, normalization, repair or transcoding
policy.

PBF StringTable IDs, protobuf field numbers, compact-store slots/pool offsets,
wire cursors and decoder plans remain implementation details.

The loss-aware PBF document/raw-preservation family is an explicit advanced
exception because callers may need to distinguish semantic rewriting from
source preservation.

## What is not promised in v0.3.x

v0.3.x does not promise:

- binary ABI stability;
- persistent/mmap store format compatibility;
- thread-safe concurrent store mutation;
- filesystem, HTTP, cache, OAuth or scheduler policy;
- changeset lifecycle management;
- spatial indexing or rendering;
- generic ordered parallel borrowed callbacks;
- compatibility of low-level wire/codec/store implementation modules;
- release qualification outside the documented compiler/platform matrix.

## Change review

A change is breaking for the supported v0.3.x surface when it can require a
conforming consumer to change source or when it weakens a documented
ownership, failure, data-integrity or lifetime guarantee.

Additive overloads/new symbols are reviewed for overload ambiguity and named
argument interactions before being classified as non-breaking.

The release consumer compile probe, package smoke, negative DIP1000 tests and
focused interoperability gates are the executable baseline for this policy.
