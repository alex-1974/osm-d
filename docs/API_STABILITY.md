# Public API and compatibility policy

## Release line

This document defines the supported source-level API contract for the first
standalone `osm-d` release line, **v0.1.x**.

The library remains pre-1.0. The v0.1.x line is deliberately stable enough for
independent consumption, but it is not an ABI promise and it does not imply
that all technically importable D modules are frozen.

The release compiler floor is D frontend **2.111** with DUB **1.40.0**.
The qualified release matrix is:

- DMD 2.111.0, 2.112.1 and 2.113.0;
- LDC 1.41.0, 1.42.0 and 1.43.0;
- Ubuntu 24.04 x86_64 for the first release gate.

Other operating systems and architectures may work, but v0.1.0 makes no
release-qualified portability claim for them.

## Compatibility promise

Within v0.1.x, patch releases preserve the supported source API unless a
security or correctness defect makes preservation impossible. In particular,
a patch release does not deliberately remove or rename supported symbols,
change parameter order or supported parameter names, weaken ownership/lifetime
contracts, change documented failure semantics, or narrow legal input solely
for convenience.

Because this is a pre-1.0 library, **v0.2.0 may contain breaking API changes**.
Such changes must be deliberate, documented in the changelog, and accompanied
by migration guidance when practical.

The compatibility promise is source-level. There is no binary ABI guarantee
between D compiler versions or osm-d releases.

For supported ordinary functions and methods, parameter names are part of the
source contract because D named arguments can depend on them. Representative
named-argument calls are compiled by the release consumer probe.

## Curated package root

`import osm;` is the preferred entry point for the PBF and compact-store
families. Its v0.1.x exports are intentional:

- semantic identity and views: `OsmId`, `ElementType`, `LocationView`,
  `MetadataView`, `TagView`, `WayNodeView`, `RelationMemberView`;
- borrowed PBF reading: `PbfReader`, `PbfReaderWorkspace`,
  `PbfNodeIterable`, `PbfWayIterable`, `PbfRelationIterable`,
  `PbfParallelReader`, `PbfParallelReadOptions`, `PbfReadSummary`,
  `PbfReadStatus`, `PbfReadError`;
- durable semantic model: `OwnedTag`, `OwnedMetadata`, `OwnedWayNode`,
  `OwnedRelationMember`, `OwnedNode`, `OwnedWay`, `OwnedRelation`,
  `OwnedDataset`, `OwnedBytes`, `ownBytes`;
- loss-aware PBF document/write boundary: `PbfDocument`, `PbfHeader`,
  `PbfHeaderBBox`, `PbfRawFile`, `PbfPreservation`,
  `PbfPreservationReason`, `readPbfDocument`, `PbfWriter`,
  `PbfWriteOptions`, `PbfWriteStatus`, `PbfWriteError`;
- semantic comparison helpers exported by the package root;
- edit model: `ChangeAction`, `ChangeObjectState`,
  `OwnedChangeEntry`, `OwnedChangeSequence`;
- compact store: `OsmStore`, `OsmHandle`, store views/ranges/status,
  primary lookup, parent navigation, `remapId`, and `readPbfStore`.

The exact root export list is compiled by the external release-consumer gate.

## Supported direct-import modules

The following direct imports are supported on v0.1.x:

- `osm`;
- `osm.store`;
- `osm.xml`;
- `osm.osmchange`;
- `osm.validate`;
- `osm.model.owned`;
- `osm.model.change`;
- `osm.model.compare`;
- `osm.raw.pbf`;
- `osm.view.element`;
- `osm.view.location`;
- `osm.view.metadata`;
- `osm.view.tag`;
- `osm.view.way_node`;
- `osm.view.relation_member`;
- `osm.io.pbf.reader`;
- `osm.io.pbf.parallel_reader`;
- `osm.io.pbf.document`;
- `osm.io.pbf.document_reader`;
- `osm.io.pbf.writer`.

The high-level XML, osmChange and upload-validation facades are the supported
entry points for those families. Their underlying `osm.io.xml.*`,
`osm.io.osmchange.*` and `osm.validation.*` modules are implementation
organization, not an additional compatibility promise.

Other `osm.io.pbf.*`, `osm.wire.*`, `osm.util.*`,
`osm.store.compact.*` and `osm.store.mapped.*` modules are not supported
direct-import compatibility surfaces even if D makes declarations technically
importable.

## Ownership and lifetime

Borrowed PBF views are valid only for the documented synchronous callback or
foreach body and while their source input/workspace remains valid.
`NodeView` is deliberately non-copyable. Borrowed tag/member/reference ranges
may be copied as cursors but do not become owners of their backing data.

The owned semantic model owns durable child arrays/byte strings according to
normal D value/array semantics; `deepCopy` creates independently mutable child
arrays where the type provides it.

`OsmStore` owns all semantics inserted into it. `OsmHandle` is an opaque
store-local logical identity, not an address or OSM ID. Store semantic views
and ranges are borrows invalidated by structural mutation as documented.

`readPbfStore` borrows encoded PBF bytes only for the call. On success the
returned store no longer depends on the input bytes.

XML and osmChange streaming readers/writers borrow/own through transport-d's
`ByteSource`/`ByteSink` contracts. The osm-d facade does not create a
second filesystem/network abstraction.

## Failure and output-state contract

Fallible public operations use explicit boolean/status results rather than
silently repairing input.

Important `.init` meanings on v0.1.x include:

- `PbfReadStatus.init`, `PbfWriteStatus.init`,
  `PbfStoreReadStatus.init`, XML/osmChange status values,
  `StoreStatus.init`, and `UploadValidationIssue.init`: success/no error;
- `PbfReaderWorkspace.init`: valid empty reusable workspace;
- `PbfWriter.init`, XML writer/reader option structs and osmChange
  option structs: usable defaults where documented;
- `PbfParallelReadOptions.init`: automatic worker/queue defaults;
- `LocationView.init`: exact coordinate origin;
- `OsmHandle.init`: invalid handle;
- owned element/data structs at `.init`: empty structural carriers, not an
  assertion that ID zero is valid editable/upload state.

For D `out` parameters, the destination is initialized to `.init` on
entry. Transactional whole-document/store APIs document the output state after
failure. Streaming callbacks already delivered before a later XML/osmChange
failure are not rolled back.

## Safety and attributes

The supported high-level API is designed for ordinary `@safe` use.
Claims such as `@safe`, `nothrow`, `@nogc` and DIP1000 lifetime behavior
are contracts only where they are present on the declaration/documentation and
are exercised by compile tests.

`PbfParallelReader.readSummary` and the XML/osmChange streaming internals use
narrow `@trusted` boundaries to establish safe ownership/lifetime contracts
over thread or parser machinery. The low-level implementation does not become
part of the public contract merely because a high-level operation is safe.

## Semantic versus codec-specific types

The supported consumer boundary uses semantic OSM concepts whenever possible.
PBF StringTable IDs, protobuf field numbers, block offsets used only for codec
execution, decompression buffers, compact-store pool offsets and hash-table
slots are implementation details.

The explicit exception is the loss-aware PBF document/raw-preservation family:
those public types exist because callers need to distinguish semantic rewrite
from exact-source preservation.

## What is not promised in v0.1.x

v0.1.x does not promise:

- binary ABI stability;
- persistent/mmap store format compatibility;
- thread-safe concurrent store mutation;
- filesystem, HTTP, cache or scheduler policy;
- spatial indexing or rendering;
- generic ordered parallel borrowed callbacks;
- compatibility of low-level wire/codec implementation modules;
- release qualification on platforms outside the documented matrix.

## Change review

A change is treated as breaking for the supported v0.1.x surface when it can
require a conforming consumer to change source or when it weakens a documented
ownership, failure, data-integrity or lifetime guarantee. Additive overloads or
new symbols are reviewed for overload ambiguity before being classified as
non-breaking.

The release consumer compile probe, negative DIP1000 tests and package smoke
are the executable baseline for this policy.
