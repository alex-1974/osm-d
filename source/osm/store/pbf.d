/**
 * Direct validated PBF -> OsmStore construction.
 *
 * The reader feeds borrowed semantic PBF views directly into the durable store.
 * No PbfDocument or OwnedDataset intermediate is materialized. On success the
 * returned store owns all semantic bytes and does not depend on input lifetime.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-04
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.store.pbf;

import osm.io.pbf.reader :
    PbfReadStatus,
    PbfSourceReadStatus,
    PbfReadSummary,
    PbfReader,
    PbfReaderWorkspace;
import osm.store.compact.store :
    OsmStore,
    StoreStatus;
import transport.source : ByteSource;

/**
 * Combined diagnostic for one direct PBF-to-store read.
 *
 * Exactly one or both nested statuses may carry a failure. PBF decoding
 * continues after a store-semantic rejection where possible, so malformed file
 * content discovered later is not hidden by an earlier store rejection.
 *
 * .init is the successful status.
 */
struct PbfStoreReadStatus
{
    PbfReadStatus pbf;
    StoreStatus store;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return pbf.ok && store.ok;
    }
}

struct PbfSourceStoreReadStatus
{
    PbfSourceReadStatus source;
    StoreStatus store;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return source.ok && store.ok;
    }
}

private struct StoreSink
{
    OsmStore target;
    StoreStatus status;
    bool failed;

    void node(Node)(scope ref Node value) @safe nothrow @nogc
    {
        if (!failed && !target.addBorrowedNode(value, status))
            failed = true;
    }

    void way(Way)(scope ref Way value) @safe nothrow @nogc
    {
        if (!failed && !target.addBorrowedWay(value, status))
            failed = true;
    }

    void relation(Relation)(scope ref Relation value) @safe nothrow @nogc
    {
        if (!failed && !target.addBorrowedRelation(value, status))
            failed = true;
    }
}

/**
 * Read one complete in-memory PBF directly into a compact editable OSM store.
 *
 * The complete input must remain alive only for this call. The returned store
 * owns its IDs, coordinates, metadata, tags, Way references, Relation members,
 * strings, primary indexes and parent indexes.
 *
 * Construction is transactional at the public boundary: on any PBF or
 * store-semantic failure, store is null and summary is reset. status retains
 * the applicable diagnostics.
 *
 * The selected M6 path is single-writer and uses one reusable PbfReaderWorkspace.
 * It does not allocate a worker queue or block-local staging stores. This keeps
 * temporary memory bounded by the largest reader workspace plus the growing
 * durable store. Parallel staging was deliberately not made part of this API;
 * see ADR 0024.
 */
bool readPbfStore(
    scope const(ubyte)[] input,
    out OsmStore store,
    out PbfReadSummary summary,
    out PbfStoreReadStatus status) @safe
{
    store = null;
    summary = PbfReadSummary.init;
    status = PbfStoreReadStatus.init;

    auto candidate = new OsmStore();

    PbfReader reader;
    PbfReaderWorkspace workspace;
    StoreSink sink;
    sink.target = candidate;

    PbfReadStatus pbfStatus;
    PbfReadSummary readSummary;

    // SAFETY: PbfReader.read is synchronous and does not retain input or
    // handler-borrowed element views after the call. StoreSink copies every
    // accepted semantic value into target-owned storage before returning from
    // each callback. This narrow bridge compensates for the older generic
    // reader signature not carrying an explicit scope parameter.
    const pbfOk = (() @trusted {
        return reader.read(
            input, workspace, sink, readSummary, pbfStatus);
    })();

    status.pbf = pbfStatus;
    if (sink.failed)
        status.store = sink.status;

    if (!pbfOk || sink.failed)
    {
        // The partial candidate never escapes this call.
        candidate = null;
        return false;
    }

    store = candidate;
    summary = readSummary;
    return true;
}


bool readPbfStore(
    scope ByteSource inputSource,
    out OsmStore store,
    out PbfReadSummary summary,
    out PbfSourceStoreReadStatus status) @safe
{
    store = null;
    summary = PbfReadSummary.init;
    status = PbfSourceStoreReadStatus.init;

    auto builtStore = new OsmStore();
    PbfReader reader;
    PbfReaderWorkspace workspace;
    StoreSink sink;
    sink.target = builtStore;

    PbfReadSummary readSummary;
    PbfSourceReadStatus readStatus;
    const ok = reader.read(
        inputSource, workspace, sink, readSummary, readStatus);

    status.source = readStatus;
    if (sink.failed)
        status.store = sink.status;

    if (!ok || sink.failed)
        return false;

    store = builtStore;
    summary = readSummary;
    return true;
}

unittest
{
    // Empty input is not a valid PBF and never exposes a partial store.
    OsmStore store;
    PbfReadSummary summary;
    PbfStoreReadStatus status;
    assert(!readPbfStore(null, store, summary, status));
    assert(store is null);
    assert(!status.pbf.ok);
    assert(status.store.ok);
}


unittest
{
    import osm.io.pbf.document : PbfDocument;
    import osm.io.pbf.writer : PbfWriteStatus, PbfWriter;
    import osm.model.owned :
        OwnedDataset,
        OwnedNode,
        OwnedRelation,
        OwnedRelationMember,
        OwnedWay,
        OwnedWayNode;
    import osm.view.element : ElementType;
    import osm.view.location : LocationView;

    OwnedDataset data;

    OwnedNode node;
    node.id = 1;
    node.location = LocationView(48_000_000_000L, 16_000_000_000L);
    data.nodes ~= node;

    OwnedWay way;
    way.id = 2;
    way.nodes ~= OwnedWayNode(1, false, LocationView.init);
    data.ways ~= way;

    OwnedRelation relation;
    relation.id = 3;
    OwnedRelationMember member;
    member.type = ElementType.way;
    member.id = 2;
    relation.members ~= member;
    data.relations ~= relation;

    auto document = PbfDocument.create(data);

    PbfWriter writer;
    PbfWriteStatus writeStatus;
    ubyte[] bytes;
    assert(writer.write(document, bytes, writeStatus));

    OsmStore store;
    PbfReadSummary summary;
    PbfStoreReadStatus status;
    assert(readPbfStore(bytes, store, summary, status));
    assert(status.ok);
    assert(store !is null);
    assert(summary.nodes == 1);
    assert(summary.ways == 1);
    assert(summary.relations == 1);

    import transport.source : MemorySource;

    OsmStore streamedStore;
    PbfReadSummary streamedSummary;
    PbfSourceStoreReadStatus streamedStatus;
    assert(readPbfStore(
        new MemorySource(bytes),
        streamedStore,
        streamedSummary,
        streamedStatus));
    assert(streamedStatus.ok);
    assert(streamedSummary == summary);
    assert(streamedStore.counts == store.counts);

    auto parents = store.parentWays(1);
    assert(!parents.empty);
    assert(parents.front.id == 2);

    auto relationParents =
        store.parentRelations(ElementType.way, 2);
    assert(!relationParents.empty);
    assert(relationParents.front.id == 3);
}

unittest
{
    // A PBF that is codec-valid but violates the editable-store tag contract
    // fails at the public boundary without exposing the partially built store.
    import osm.io.pbf.document : PbfDocument;
    import osm.io.pbf.writer : PbfWriteStatus, PbfWriter;
    import osm.model.owned : OwnedDataset, OwnedNode, OwnedTag, ownBytes;
    import osm.view.location : LocationView;

    OwnedDataset data;
    OwnedNode node;
    node.id = 1;
    node.location = LocationView(1, 2);
    node.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"first"));
    node.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"second"));
    data.nodes ~= node;

    auto document = PbfDocument.create(data);
    PbfWriter writer;
    PbfWriteStatus writeStatus;
    ubyte[] bytes;
    assert(writer.write(document, bytes, writeStatus));

    OsmStore store;
    PbfReadSummary summary;
    PbfStoreReadStatus status;
    assert(!readPbfStore(bytes, store, summary, status));
    assert(store is null);
    assert(status.pbf.ok);
    assert(!status.store.ok);
    assert(summary.nodes == 0);
}
