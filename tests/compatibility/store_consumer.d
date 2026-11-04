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

    OsmHandle found;
    assert(store.find(ElementType.node, 1, found));
    assert(found == handle);

    StoreNodeView view;
    assert(store.node(found, view, status));
    assert(view.id == 1);

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

    StoreMemoryUsage usage = store.memoryUsage;
    StoreCounts counts = store.counts;
    assert(usage.totalOwnedBytes > 0);
    assert(counts.liveNodes == 1);
}

void main()
{
    compileStoreSurface();
}
