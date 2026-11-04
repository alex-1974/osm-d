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
- `import osm.validate;` — upload-readiness validation;
- `import osm.upload;` — bounded OSM API diffResult response parsing;
- `import osm.capabilities;` — Editing API capability discovery projected
  into upload-validation policy.

Low-level protobuf/wire, XML parser internals, validation implementation
modules and compact-store representation modules are not part of this
compatibility surface.

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
  `collectChanges`, `applyUploadResult`, and `readPbfStore`;
- ordinary borrowed PBF reading: `PbfReader`, `PbfReaderWorkspace`,
  element-specific iterables, `PbfReadSummary`, `PbfReadStatus`,
  `PbfReadError`, `PbfReadResult`, `readPbf`,
  `pbfNodes`/`pbfWays`/`pbfRelations`.

Loss-aware PBF documents/writing and parallel-summary facilities deliberately
live in `osm.pbf` rather than the root.

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

## Failure and `.init` contract

Fallible public operations use explicit success/status channels rather than
silently repairing input.

Important meanings include:

- read/write/store status structs and `UploadValidationIssue.init`: success /
  no error;
- `PbfReaderWorkspace.init`: valid empty reusable workspace;
- writer/reader option structs: documented usable defaults;
- `LocationView.init`: exact coordinate origin;
- `OsmHandle.init`: invalid handle;
- `OwnedDataset.init`, `OwnedChangeSequence.init`, `UploadResult.init`:
  valid empty carriers;
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
