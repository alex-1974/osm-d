# Getting started with osm-d

The latest published release is v0.1.0. Current `develop` is preparing the
v0.2 consumer API described in `API_V0_2.md`.

## Add the published dependency

```sdl
dependency "osm-d" version="~>0.1.0"
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

Before an `OwnedChangeSequence` is used for an OSM API-style upload, run
`validateUploadChanges` from `osm.validate` with the target
`CapabilityProfile`.

## Naming and migration

A Way contains Node references. v0.2 therefore uses `NodeRefView` and
`OwnedNodeRef` rather than the v0.1 `WayNodeView`/`OwnedWayNode` names.

See `API_V0_2.md` for the complete migration table and workspace-library
reuse decisions. The immutable v0.1.x contract remains in
`API_STABILITY.md`.
