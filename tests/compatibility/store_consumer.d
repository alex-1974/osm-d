module store_consumer;

import osm;

void compileStoreSurface()
{
    auto store = new OsmStore();

    OwnedNode node;
    node.id = 1;
    node.location = LocationView(48_208_174_300L, 16_373_818_900L);

    OsmHandle handle;
    StoreStatus status;
    bool added = store.add(node, handle, status);
    assert(added && status.ok);

    StoreNodeView view;
    assert(store.node(1, view, status));
    assert(view.id == 1);
    assert(view.handle == handle);

    OsmHandle found;
    assert(store.find(ElementType.node, 1, found));
    assert(found == handle);

    auto nodes = store.nodes;
    if (!nodes.empty)
    {
        auto current = nodes.front;
        assert(current.handle == handle);
    }

    OwnedNode copy;
    assert(store.copyNode(handle, copy, status));
    copy.location = LocationView(48_000_000_000L, 16_000_000_000L);
    assert(store.replace(handle, copy, status));

    assert(store.remove(handle, status));
    StoreElementState state;
    assert(store.state(handle, state, status));
    assert(state == StoreElementState.deleted);
    assert(store.restore(handle, status));

    // Store leaf values reuse the common semantic view family.
    static assert(is(typeof(view.metadata) == MetadataView));
    static assert(is(typeof(view.tags.front) == TagView));

    StoreParentWayRange wayParents = store.parentWays(1);
    StoreParentRelationRange relationParents =
        store.parentRelations(ElementType.node, 1);
    assert(wayParents.empty);
    assert(relationParents.empty);

    auto local = new OsmStore();
    OwnedNode localNode;
    localNode.id = -1;
    localNode.location = LocationView(1, 2);
    OsmHandle localHandle;
    assert(local.add(localNode, localHandle, status));
    assert(local.remapId(localHandle, 1001, 1, status));

    StoreNodeView remapped;
    assert(local.node(1001, remapped, status));
    assert(remapped.handle == localHandle);

    StoreNodeView missing;
    assert(!local.node(9999, missing, status));
    assert(status.error == StoreError.notFound);

    StoreMemoryUsage usage = store.memoryUsage;
    StoreCounts counts = store.counts;
    assert(usage.totalOwnedBytes > 0);
    assert(counts.liveNodes == 1);

    OsmStore directStore;
    PbfReadSummary directSummary;
    PbfStoreReadStatus directStatus;
    const(ubyte)[] pbfBytes;
    bool directOk = readPbfStore(
        pbfBytes,
        directStore,
        directSummary,
        directStatus);
    assert(!directOk);
    assert(directStore is null);
    assert(!directStatus.pbf.ok);
}

void main()
{
    compileStoreSurface();
}
