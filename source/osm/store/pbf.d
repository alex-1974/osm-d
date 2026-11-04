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

import core.lifetime : destroy;

import osm.io.pbf.reader :
    PbfReadStatus,
    PbfReadSummary,
    PbfReader,
    PbfReaderWorkspace;
import osm.store.compact.store :
    OsmStore,
    StoreStatus;

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
    const pbfOk =
        reader.read(input, workspace, sink, readSummary, pbfStatus);

    status.pbf = pbfStatus;
    if (sink.failed)
        status.store = sink.status;

    if (!pbfOk || sink.failed)
    {
        // Release the deterministic high-volume store buffers immediately.
        destroy(candidate);
        candidate = null;
        return false;
    }

    store = candidate;
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
