# Getting started with osm-d v0.1.x

## Add the dependency

```sdl
dependency "osm-d" version="~>0.1.0"
```

The v0.1.x release floor is D frontend 2.111 and DUB 1.40.0. The full qualified
matrix is recorded in `API_STABILITY.md`.

## Choose the right PBF API

Use `PbfReader` when you want maximum-throughput borrowed traversal without
materializing the dataset. Callback/foreach views are borrowed; copy only the
semantic values that must outlive the callback.

Use `readPbfStore` when you need durable random access and editing. It builds
the indexed `OsmStore` directly from validated PBF bytes and does not retain
the input buffer after the call.

Use `readPbfDocument` when you need a durable loss-aware PBF document for
read/modify/write work. Before semantic rewriting, inspect preservation state;
`PbfWriter` fails closed when the source contains content the semantic model
cannot preserve.

Repository examples:

- `examples/pbf-read` — borrowed semantic traversal;
- `examples/pbf-store` — direct PBF to editable indexed store;
- `examples/pbf-roundtrip` — durable loss-aware PBF read/write;
- `examples/xml-roundtrip` — ordinary OSM XML through transport-d;
- `examples/osmchange-roundtrip` — osmChange read/write plus validation.

Each example is a standalone DUB package and is compiled by the release gate.

## Borrowed traversal

```d
import osm;

struct Handler
{
    ulong nodes;

    void node(scope ref NodeView node) @safe nothrow @nogc
    {
        ++nodes;
        const id = node.id;
        const location = node.location;

        auto tags = node.tags;
        while (!tags.empty)
        {
            const tag = tags.front;
            tags.popFront();
        }
    }
}

PbfReader reader;
PbfReaderWorkspace workspace;
Handler handler;
PbfReadSummary summary;
PbfReadStatus status;

if (!reader.read(pbfBytes, workspace, handler, summary, status))
{
    // status identifies the high-level failure and file block.
}
```

A naturally completed foreach traversal validates the complete file. Breaking
out of a foreach intentionally leaves the unvisited suffix unvalidated.

## Editable random access

```d
OsmStore store;
PbfReadSummary summary;
PbfStoreReadStatus status;

if (readPbfStore(pbfBytes, store, summary, status))
{
    OsmHandle node;
    if (store.find(ElementType.node, 123, node))
    {
        StoreNodeView view;
        StoreStatus storeStatus;
        if (store.node(node, view, storeStatus))
        {
            // view borrows from store until structural mutation.
        }
    }

    auto parentWays = store.parentWays(123);
}
```

`OsmHandle` is stable logical identity across ordinary replacement,
delete/restore and server-ID remapping. It is not an address and
`OsmHandle.init` is invalid.

## XML and osmChange

The high-level facades are `osm.xml` and `osm.osmchange`. They accept
transport-d `ByteSource`/`ByteSink` objects; osm-d deliberately does not
invent separate file/network abstractions.

Materializing helpers such as `readOsmXmlDocument` and
`readOsmChangeDocument` are transactional at the document boundary.
Streaming reader callbacks already delivered before a later input error are not
rolled back.

Before an `OwnedChangeSequence` is used for OSM API-style upload, run
`validateUploadChanges` with a target `CapabilityProfile`. Validation does
not reorder or repair input.

## Compatibility

Use the documented high-level facades rather than low-level `osm.wire.*` or
codec implementation modules. The exact v0.1.x source-compatibility boundary,
parameter-name policy, `.init` semantics and lifetime contracts are in
`API_STABILITY.md`.
