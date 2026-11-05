module store_consumer;

import osm;
import std.algorithm.iteration : filter, map;
import std.range : take;
import std.range.primitives : isInputRange;

static assert(isInputRange!StoreTagRange);
static assert(isInputRange!StoreNodeRefRange);
static assert(isInputRange!StoreRelationMemberRange);
static assert(isInputRange!StoreParentWayRange);
static assert(isInputRange!StoreParentRelationRange);
static assert(isInputRange!StoreNodeRange);
static assert(isInputRange!StoreWayRange);
static assert(isInputRange!StoreRelationRange);

// Preferred v0.2 root stays focused on common semantic/store/traversal APIs.
static assert(!__traits(compiles, PbfDocument.init),
    "PbfDocument is intentionally not a root export; import osm.pbf");
static assert(!__traits(compiles, PbfParallelReader.init),
    "PbfParallelReader is intentionally not a root export; import osm.pbf");
static assert(!__traits(compiles, StoreTagView.init),
    "store leaf values use TagView");
static assert(!__traits(compiles, StoreMetadataView.init),
    "store leaf values use MetadataView");

void compileStoreSurface()
{
    auto store = new OsmStore();

    OwnedNode node;
    node.id = 1;
    node.location = LocationView(48_208_174_300L, 16_373_818_900L);
    node.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"Wien"));
    node.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"place"),
        ownBytes(cast(const(ubyte)[])"city"));

    OsmHandle handle;
    StoreStatus status;
    bool added = store.add(node, handle, status);
    assert(added && status.ok);

    StoreNodeView view;
    assert(store.node(1, view, status));
    assert(view.id == 1);
    assert(view.handle == handle);

    assert(view.tags.hasTag("name"));
    assert(view.tags.tagEquals("place", "city"));
    assert(!view.tags.hasTag("highway"));

    TagView nameTag;
    assert(view.tags.findTag("name", nameTag));
    assert(nameTag.value == cast(const(ubyte)[])"Wien");

    OsmHandle found;
    assert(store.find(ElementType.node, 1, found));
    assert(found == handle);

    auto nodes = store.nodes;
    if (!nodes.empty)
    {
        auto current = nodes.front;
        assert(current.handle == handle);
    }

    // Store traversal is a real lazy D InputRange. Phobos adapters retain the
    // borrowed store-view semantics and do not materialize result arrays.
    auto namedNodes = store.nodes.filter!(value => value.tags.hasTag("name"));
    assert(!namedNodes.empty);
    assert(namedNodes.front.id == 1);

    auto nodeIds = store.nodes.map!(value => value.id);
    assert(!nodeIds.empty);
    assert(nodeIds.front == 1);

    auto firstNode = store.nodes.take(1);
    assert(!firstNode.empty);
    assert(firstNode.front.id == 1);

    // Copying a range copies cursor state only; both cursors still borrow the
    // same store and remain independently traversable until structural mutation.
    auto cursorA = store.nodes;
    auto cursorB = cursorA;
    cursorA.popFront();
    assert(cursorA.empty);
    assert(!cursorB.empty);
    assert(cursorB.front.id == 1);

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

    StoreWayView typeProbeWay;
    StoreRelationView typeProbeRelation;
    static assert(is(typeof(typeProbeWay.nodes.front) == NodeRefView));
    static assert(is(typeof(typeProbeRelation.members.front) == RelationMemberView));

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

    OwnedChangeSequence pending;
    assert(store.collectChanges(pending, status));
    assert(pending.empty);

    auto uploadStore = new OsmStore();
    OwnedNode uploadNode;
    uploadNode.id = -11;
    uploadNode.location = LocationView(48_000_000_000L, 16_000_000_000L);
    OsmHandle uploadHandle;
    assert(uploadStore.add(uploadNode, uploadHandle, status));

    assert(uploadStore.collectChanges(pending, status));
    assert(pending.entries.length == 1);
    assert(pending.setChangeset(77));

    UploadResult uploadResult;
    uploadResult.entries ~= UploadResultEntry.created(
        ElementType.node, -11, 1011, 1);
    assert(uploadStore.applyUploadResult(pending, uploadResult, status));

    StoreNodeView uploadedNode;
    assert(uploadStore.node(1011, uploadedNode, status));
    assert(uploadedNode.handle == uploadHandle);
    assert(uploadedNode.metadata.versionNumber == 1);
    assert(uploadedNode.metadata.changesetId == 77);

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
