# Getting started with osm-d

This guide targets the v0.3.x consumer API. The v0.1 -> v0.2 and
v0.2 -> v0.3 migrations are summarized in `API_V0_2.md` and
`API_V0_3.md`; the supported v0.3.x compatibility contract is
`API_STABILITY.md`.

## Add the dependency

```sdl
dependency "osm-d" version="~>0.3.0"
```

The current release floor is D frontend 2.111 and DUB 1.40.0.

## Read a PBF once

For a one-shot in-memory PBF read, use the convenience function:

```d
import osm;

struct Handler
{
    ulong nodes;

    void node(scope ref NodeView node) @safe nothrow @nogc
    {
        ++nodes;

        auto tags = node.tags;
        while (!tags.empty)
        {
            TagView tag = tags.front;
            tags.popFront();
        }
    }
}

Handler handler;
auto result = readPbf(pbfBytes, handler);

if (!result.ok)
{
    // result.status identifies the high-level failure and file block.
}
```

Borrowed element views are valid only for their synchronous callback/body.

### Read PBF from a bounded byte source

When the encoded file is not already resident, reuse the workspace reader with
the transport abstraction:

```d
import osm;
import transport : ByteSource, FileSource, ReadError;

ByteSource source = new FileSource("region.osm.pbf");

PbfReader reader;
PbfReaderWorkspace workspace;
PbfReadSummary summary;
PbfSourceReadStatus status;
Handler handler;

if (!reader.read(source, workspace, handler, summary, status))
{
    if (status.transportError != ReadError.none)
    {
        // generic byte-resource failure
    }
    else
    {
        // status.pbf identifies the PBF failure
    }
}
```

The source path does not materialize the complete PBF. It reuses bounded
current-block and decode scratch. File/HTTP behavior remains in transport-d.
Loss-aware `PbfDocument` reading is intentionally separate because preserving
the exact raw source requires retaining the encoded bytes.

### Reuse scratch storage across many reads

The explicit reader remains the high-throughput/reuse API:

```d
PbfReader reader;
PbfReaderWorkspace workspace;

foreach (input; manyPbfInputs)
{
    PbfReadSummary summary;
    PbfReadStatus status;
    Handler handler;

    if (!reader.read(input, workspace, handler, summary, status))
    {
        // handle failure
    }
}
```

### Iterate one element kind

```d
auto nodes = pbfNodes(pbfBytes);

foreach (scope ref NodeView node; nodes)
{
    if (node.id == wantedId)
        break;
}
```

Use `pbfWays` and `pbfRelations` analogously. Natural completion validates
the complete file. Breaking early intentionally leaves the unvisited suffix
unvalidated.

## Load an editable store

```d
OsmStore store;
PbfReadSummary summary;
PbfStoreReadStatus readStatus;

if (readPbfStore(pbfBytes, store, summary, readStatus))
{
    StoreNodeView node;
    StoreStatus status;

    if (store.node(123, node, status))
    {
        auto handle = node.handle;
        auto tags = node.tags;          // TagView values
        auto metadata = node.metadata; // MetadataView
    }

    auto parentWays = store.parentWays(123);
}
```

Typed `node/way/relation(id, ...)` lookup is the ordinary read path.
`OsmHandle` remains the stable identity for editor operations, replacement,
delete/restore, revert and server-ID remapping.

Store leaf values use the same semantic vocabulary as PBF:
`TagView`, `MetadataView`, `NodeRefView` and `RelationMemberView`.

## Turn store edits into an upload

The store exports OSM change semantics, not XML. Server policy is discovered
through the focused capabilities facade rather than hardcoded:

```d
import osm;
import osm.capabilities;
import osm.osmchange;
import osm.upload;
import osm.validate;

EditingApiCapabilitiesDocument capabilityDocument;
ApiCapabilitiesReadStatus capabilityStatus;

if (!readEditingApiCapabilities(
        capabilitiesResponseSource,
        capabilityDocument,
        capabilityStatus))
    return;

CapabilityProfile capabilities =
    capabilityDocument.capabilities.validationProfile;

OwnedChangeSequence changes;
StoreStatus status;

if (!store.collectChanges(changes, status))
{
    // unresolved/circular local dependency
    return;
}

if (changes.empty)
    return;

if (!changes.setChangeset(openChangesetId))
    return;

UploadValidationIssue issue;
if (!validateUploadChanges(changes, capabilities, issue))
    return;

// Encode only at the interchange boundary.
auto sink = new MemorySink();
OsmChangeWriter writer;
OsmChangeWriteStatus writeStatus;
if (!writer.writeChanges(changes, sink, writeStatus))
    return;
```

The application remains responsible for obtaining the capabilities response,
opening/closing the changeset, HTTP/OAuth and sending the generated body.

`collectChanges` copies only pending edit state into a durable
`OwnedChangeSequence`. It does not invent a changeset ID. Created local
dependencies are ordered so ordinary Node -> Way -> Relation references are
uploadable; circular local Relation placeholders fail explicitly.

After a successful diff upload, parse the server's XML response directly:

```d
UploadResult result;
UploadResultReadStatus resultStatus;

if (!readUploadResult(uploadResponseSource, result, resultStatus))
    return;

if (!store.applyUploadResult(changes, result, status))
{
    // The store changed since 'changes' was materialized, or the result does
    // not match the request. No acknowledgement was partially applied.
}
```

Raw diffResult shape does not reliably identify create/modify/delete. When
individual result semantics are needed, call
`UploadResultEntry.effectFor(uploadedEntry, effect)` with the exact request
entry.

Create and modify acknowledgements preserve the element handle. Create also
remaps inbound references to the authoritative server ID. A confirmed delete
invalidates the deleted object's old handle.

## Loss-aware PBF read/write

Specialized PBF document/preservation/write functionality has a focused facade:

```d
import osm;
import osm.pbf;

PbfDocument document;
PbfReadStatus readStatus;

if (readPbfDocument(pbfBytes, document, readStatus))
{
    PbfWriter writer;
    PbfWriteStatus writeStatus;
    ubyte[] output;

    if (!writer.write(document, output, writeStatus))
    {
        // Semantic rewriting was unsafe or invalid; failure is explicit.
    }
}
```

## XML and osmChange

Use `osm.xml` and `osm.osmchange`. They accept transport-d
`ByteSource`/`ByteSink` resources; osm-d does not duplicate file/network
transport abstractions.

Before an `OwnedChangeSequence` is used for an OSM API-style upload, read the
target policy with `osm.capabilities` when online and run
`validateUploadChanges` from `osm.validate` with the resulting
`CapabilityProfile`. Offline consumers may still supply an explicit local
policy or use `CapabilityProfile.unbounded()` when only semantic validation is
wanted.

## Naming and migration

A Way contains Node references. v0.2 introduced `NodeRefView` and
`OwnedNodeRef` rather than the v0.1 `WayNodeView`/`OwnedWayNode` names.

v0.3 adds `osm.upload` and `osm.capabilities` and removes the ambiguous
v0.2-only `UploadResultEntry.action` compatibility property. Use
`effectFor` with the matching uploaded request entry.

See `API_V0_2.md` and `API_V0_3.md` for migration guidance.
`API_STABILITY.md` defines the supported v0.3.x patch-line contract.
