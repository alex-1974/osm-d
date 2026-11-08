module app;

import osm.store;
import osm.sync;
import osm.model.owned :
    OwnedNode,
    OwnedNodeRef,
    OwnedRelation,
    OwnedRelationMember,
    OwnedTag,
    OwnedWay,
    ownBytes;
import osm.view.element : ElementType;
import osm.view.location : LocationView;

@safe void main()
{
    qualifyHistory();
    qualifyConflictClassification();
    qualifyConflictEdges();
    qualifyReconciliation();
    qualifyConcurrentReconciliation();
    qualifyParentIndexRefresh();
    qualifyAuthoritativeRevival();
    qualifyTransactionalPreflight();
}

private void qualifyHistory() @safe
{
    OwnedNode v1;
    v1.id = 100;
    v1.metadata.hasVersion = true;
    v1.metadata.versionNumber = 1;
    v1.metadata.hasVisibility = true;
    v1.metadata.visible = true;
    v1.location = LocationView(48_200_000_000L, 16_300_000_000L);

    auto hv1 = HistoricalNodeVersion.fromOwned(v1);

    HistoricalNodeVersion hv2;
    hv2.id = v1.id;
    hv2.metadata = v1.metadata;
    hv2.metadata.versionNumber = 2;
    hv2.metadata.visible = false;

    NodeHistory history;
    HistoryStatus status;
    assert(NodeHistory.create(
        [hv1, hv2],
        HistoryCoverage.complete,
        history,
        status));
    assert(history.length == 2);
    assert(history.findVersion(2).length == 1);
    assert(history.visibility(2) == HistoricalVisibility.deleted);

    OwnedWay w2;
    w2.id = 200;
    w2.metadata.hasVersion = true;
    w2.metadata.versionNumber = 2;
    auto hw2 = HistoricalWayVersion.fromOwned(w2);
    auto hw4 = hw2.deepCopy();
    hw4.metadata.versionNumber = 4;

    WayHistory partial;
    assert(WayHistory.create(
        [hw2, hw4],
        HistoryCoverage.partial,
        partial,
        status));
    assert(partial.hasGap);
}

private void qualifyConflictClassification() @safe
{
    OwnedNode base;
    base.id = 1;
    base.metadata.hasVersion = true;
    base.metadata.versionNumber = 7;
    base.location = LocationView(10, 20);
    base.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"base"));

    auto local = base.deepCopy();
    local.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"surface"),
        ownBytes(cast(const(ubyte)[])"paved"));

    auto remote = base.deepCopy();
    remote.metadata.versionNumber = 8;
    remote.location = LocationView(11, 20);

    auto report = classifyConflict(
        NodeState.present(base),
        NodeState.present(local),
        NodeState.present(remote));
    assert(report.disposition ==
        ConflictDisposition.concurrentIndependent);
    assert(report.tags == FieldChange.localOnly);
    assert(report.location == FieldChange.remoteOnly);

    OwnedWay baseWay;
    baseWay.id = 2;
    baseWay.metadata.hasVersion = true;
    baseWay.metadata.versionNumber = 3;
    OwnedNodeRef a;
    a.id = 10;
    OwnedNodeRef b;
    b.id = 20;
    OwnedNodeRef c;
    c.id = 30;
    baseWay.nodes = [a, b, c];

    auto localWay = baseWay.deepCopy();
    OwnedNodeRef x;
    x.id = 15;
    localWay.nodes = [a, x, b, c];

    auto remoteWay = baseWay.deepCopy();
    remoteWay.metadata.versionNumber = 4;
    OwnedNodeRef y;
    y.id = 40;
    remoteWay.nodes = [a, b, c, y];

    report = classifyConflict(
        WayState.present(baseWay),
        WayState.present(localWay),
        WayState.present(remoteWay));
    assert(report.sequence ==
        SequenceChange.independentConcurrent);

    OwnedRelation baseRelation;
    baseRelation.id = 3;
    baseRelation.metadata.hasVersion = true;
    baseRelation.metadata.versionNumber = 1;
    OwnedRelationMember member;
    member.type = ElementType.way;
    member.id = 2;
    member.role = ownBytes(cast(const(ubyte)[])"outer");
    baseRelation.members ~= member;

    auto localRelation = baseRelation.deepCopy();
    localRelation.members[0].role =
        ownBytes(cast(const(ubyte)[])"inner");

    auto remoteRelation = baseRelation.deepCopy();
    remoteRelation.metadata.versionNumber = 2;
    remoteRelation.members[0].role =
        ownBytes(cast(const(ubyte)[])"platform");

    report = classifyConflict(
        RelationState.present(baseRelation),
        RelationState.present(localRelation),
        RelationState.present(remoteRelation));
    assert(report.hasConflict);
}

private void qualifyReconciliation() @safe
{
    OwnedNode node;
    node.id = 10;
    node.metadata.hasVersion = true;
    node.metadata.versionNumber = 1;
    node.location = LocationView(100, 200);
    node.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"old"));

    OwnedWay way;
    way.id = 20;
    way.metadata.hasVersion = true;
    way.metadata.versionNumber = 1;
    OwnedNodeRef nodeRef;
    nodeRef.id = 10;
    way.nodes ~= nodeRef;

    OwnedRelation relation;
    relation.id = 30;
    relation.metadata.hasVersion = true;
    relation.metadata.versionNumber = 1;
    OwnedRelationMember member;
    member.type = ElementType.way;
    member.id = 20;
    member.role = ownBytes(cast(const(ubyte)[])"outer");
    relation.members ~= member;

    auto store = new OsmStore();
    OsmHandle nodeHandle;
    OsmHandle wayHandle;
    OsmHandle relationHandle;
    StoreStatus storeStatus;
    assert(store.add(node, nodeHandle, storeStatus));
    assert(store.add(way, wayHandle, storeStatus));
    assert(store.add(relation, relationHandle, storeStatus));

    auto localNode = node.deepCopy();
    localNode.tags[0].value =
        ownBytes(cast(const(ubyte)[])"local");
    assert(store.replace(nodeHandle, localNode, storeStatus));

    auto remoteNode = node.deepCopy();
    remoteNode.metadata.versionNumber = 2;
    remoteNode.tags[0].value =
        ownBytes(cast(const(ubyte)[])"remote");

    auto remoteWay = way.deepCopy();
    remoteWay.metadata.versionNumber = 2;
    OwnedNodeRef secondRef;
    secondRef.id = 11;
    remoteWay.nodes ~= secondRef;

    AuthoritativeBatch batch;
    batch.nodes ~= NodeState.present(remoteNode);
    batch.ways ~= WayState.present(remoteWay);
    batch.relations ~= RelationState.absent(30, 2);

    ReconcileResult result;
    ReconcileStatus status;
    assert(reconcileAuthoritative(store, batch, result, status));
    assert(status.ok);
    assert(result.conflicts == 1);
    assert(result.refreshed == 1);
    assert(result.removed == 1);

    // Local conflict remains untouched.
    OwnedNode currentNode;
    assert(store.copyNode(nodeHandle, currentNode, storeStatus));
    assert(currentNode.tags[0].value ==
        cast(const(ubyte)[])"local");

    // Clean Way was refreshed in place, including reverse-index contributions.
    OwnedWay currentWay;
    assert(store.copyWay(wayHandle, currentWay, storeStatus));
    assert(currentWay.metadata.versionNumber == 2);
    assert(currentWay.nodes.length == 2);

    size_t parentsOf11;
    auto parents = store.parentWays(11);
    while (!parents.empty)
    {
        ++parentsOf11;
        parents.popFront();
    }
    assert(parentsOf11 == 1);

    // Authoritative deletion invalidates the old Relation handle and is not
    // emitted as a local delete.
    StoreElementState ignoredState;
    assert(!store.state(relationHandle, ignoredState, storeStatus));

    OwnedChangeSequence changes;
    assert(store.collectChanges(changes, storeStatus));
    assert(changes.entries.length == 1);
    assert(changes.entries[0].type == ElementType.node);
    assert(changes.entries[0].id == 10);
}


private void qualifyConflictEdges() @safe
{
    OwnedNode base;
    base.id = 50;
    base.metadata.hasVersion = true;
    base.metadata.versionNumber = 4;
    base.location = LocationView(1, 2);
    base.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"a"));
    base.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"b"));

    auto local = base.deepCopy();
    local.tags[1].value =
        ownBytes(cast(const(ubyte)[])"local");
    auto remote = base.deepCopy();
    remote.metadata.versionNumber = 5;
    remote.tags[1].value =
        ownBytes(cast(const(ubyte)[])"remote");

    auto report = classifyConflict(
        NodeState.present(base),
        NodeState.present(local),
        NodeState.present(remote));
    assert(report.hasConflict);
    assert(report.hasDuplicateTagKeys);
    assert(report.tagChanges.length == 1);
    assert(report.tagChanges[0].duplicateKey);

    // Remote deletion versus a local payload edit is an explicit conflict.
    report = classifyConflict(
        NodeState.present(base),
        NodeState.present(local),
        NodeState.absent(50, 5));
    assert(report.hasConflict);

    // Local deletion versus a newer remote payload is also a conflict.
    report = classifyConflict(
        NodeState.present(base),
        NodeState.absent(50, 4),
        NodeState.present(remote));
    assert(report.hasConflict);

    // Identical concurrent payload produces a distinct, safe classification.
    auto sameRemote = local.deepCopy();
    sameRemote.metadata.versionNumber = 5;
    report = classifyConflict(
        NodeState.present(base),
        NodeState.present(local),
        NodeState.present(sameRemote));
    assert(report.disposition ==
        ConflictDisposition.identicalConcurrent);
    assert(report.remoteRefreshSafe);
}

private void qualifyConcurrentReconciliation() @safe
{
    OwnedNode base;
    base.id = 60;
    base.metadata.hasVersion = true;
    base.metadata.versionNumber = 1;
    base.location = LocationView(5, 6);
    base.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"base"));

    auto store = new OsmStore();
    OsmHandle handle;
    StoreStatus storeStatus;
    assert(store.add(base, handle, storeStatus));

    auto local = base.deepCopy();
    local.tags[0].value =
        ownBytes(cast(const(ubyte)[])"same");
    assert(store.replace(handle, local, storeStatus));

    auto remote = local.deepCopy();
    remote.metadata.versionNumber = 2;

    AuthoritativeBatch batch;
    batch.nodes ~= NodeState.present(remote);

    ReconcileResult result;
    ReconcileStatus status;
    assert(reconcileAuthoritative(store, batch, result, status));
    assert(result.refreshed == 1);
    assert(result.conflicts == 0);
    assert(result.deferred == 0);

    StoreElementState state;
    assert(store.state(handle, state, storeStatus));
    assert(state == StoreElementState.clean);

    OwnedChangeSequence changes;
    assert(store.collectChanges(changes, storeStatus));
    assert(changes.entries.length == 0);

    // Local delete against a changed remote object remains a local tombstone.
    OwnedNode deleteBase;
    deleteBase.id = 61;
    deleteBase.metadata.hasVersion = true;
    deleteBase.metadata.versionNumber = 3;
    deleteBase.location = LocationView(7, 8);
    OsmHandle deletedHandle;
    assert(store.add(deleteBase, deletedHandle, storeStatus));
    assert(store.remove(deletedHandle, storeStatus));

    auto changedRemote = deleteBase.deepCopy();
    changedRemote.metadata.versionNumber = 4;
    changedRemote.location = LocationView(9, 8);

    AuthoritativeBatch deleteBatch;
    deleteBatch.nodes ~= NodeState.present(changedRemote);
    assert(reconcileAuthoritative(
        store,
        deleteBatch,
        result,
        status));
    assert(result.conflicts == 1);
    assert(store.state(deletedHandle, state, storeStatus));
    assert(state == StoreElementState.deleted);
}

private void qualifyParentIndexRefresh() @safe
{
    OwnedWay way20;
    way20.id = 20;
    way20.metadata.hasVersion = true;
    way20.metadata.versionNumber = 1;

    OwnedWay way21;
    way21.id = 21;
    way21.metadata.hasVersion = true;
    way21.metadata.versionNumber = 1;

    OwnedRelation relation;
    relation.id = 70;
    relation.metadata.hasVersion = true;
    relation.metadata.versionNumber = 1;
    OwnedRelationMember member;
    member.type = ElementType.way;
    member.id = 20;
    member.role = ownBytes(cast(const(ubyte)[])"outer");
    relation.members ~= member;

    auto store = new OsmStore();
    OsmHandle ignored;
    OsmHandle relationHandle;
    StoreStatus storeStatus;
    assert(store.add(way20, ignored, storeStatus));
    assert(store.add(way21, ignored, storeStatus));
    assert(store.add(relation, relationHandle, storeStatus));

    size_t oldParents;
    auto before = store.parentRelations(ElementType.way, 20);
    while (!before.empty)
    {
        ++oldParents;
        before.popFront();
    }
    assert(oldParents == 1);

    auto remote = relation.deepCopy();
    remote.metadata.versionNumber = 2;
    remote.members[0].id = 21;

    AuthoritativeBatch batch;
    batch.relations ~= RelationState.present(remote);
    ReconcileResult result;
    ReconcileStatus status;
    assert(reconcileAuthoritative(store, batch, result, status));
    assert(result.refreshed == 1);

    size_t parents20;
    auto oldRange = store.parentRelations(ElementType.way, 20);
    while (!oldRange.empty)
    {
        ++parents20;
        oldRange.popFront();
    }
    assert(parents20 == 0);

    size_t parents21;
    auto newRange = store.parentRelations(ElementType.way, 21);
    while (!newRange.empty)
    {
        ++parents21;
        newRange.popFront();
    }
    assert(parents21 == 1);

    StoreElementState state;
    assert(store.state(relationHandle, state, storeStatus));
    assert(state == StoreElementState.clean);
}

private void qualifyTransactionalPreflight() @safe
{
    OwnedNode first;
    first.id = 80;
    first.metadata.hasVersion = true;
    first.metadata.versionNumber = 1;
    first.location = LocationView(1, 1);

    OwnedNode second;
    second.id = 81;
    second.metadata.hasVersion = true;
    second.metadata.versionNumber = 1;
    second.location = LocationView(2, 2);

    auto store = new OsmStore();
    OsmHandle firstHandle;
    OsmHandle secondHandle;
    StoreStatus storeStatus;
    assert(store.add(first, firstHandle, storeStatus));
    assert(store.add(second, secondHandle, storeStatus));

    auto firstRemote = first.deepCopy();
    firstRemote.metadata.versionNumber = 2;
    firstRemote.location = LocationView(10, 1);

    auto invalidRemote = second.deepCopy();
    invalidRemote.metadata.versionNumber = 2;
    invalidRemote.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"dup"),
        ownBytes(cast(const(ubyte)[])"a"));
    invalidRemote.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"dup"),
        ownBytes(cast(const(ubyte)[])"b"));

    AuthoritativeBatch batch;
    batch.nodes ~= NodeState.present(firstRemote);
    batch.nodes ~= NodeState.present(invalidRemote);

    ReconcileResult result;
    ReconcileStatus status;
    assert(!reconcileAuthoritative(store, batch, result, status));
    assert(status.error == ReconcileError.storePreflight);

    // The first valid plan was not applied before the later preflight failure.
    OwnedNode current;
    assert(store.copyNode(firstHandle, current, storeStatus));
    assert(current.metadata.versionNumber == 1);
    assert(current.location.latitudeNanodegrees == 1);

    // A new authoritative object may be inserted into a partial local dataset
    // even when it refers only to positive identities not currently loaded.
    OwnedWay remoteWay;
    remoteWay.id = 82;
    remoteWay.metadata.hasVersion = true;
    remoteWay.metadata.versionNumber = 1;
    OwnedNodeRef unresolvedPositive;
    unresolvedPositive.id = 999;
    remoteWay.nodes ~= unresolvedPositive;

    AuthoritativeBatch insertBatch;
    insertBatch.ways ~= WayState.present(remoteWay);
    assert(reconcileAuthoritative(
        store,
        insertBatch,
        result,
        status));
    assert(result.inserted == 1);

    StoreWayView inserted;
    assert(store.way(82, inserted, storeStatus));
    assert(inserted.nodes.length == 1);
}


private void qualifyAuthoritativeRevival() @safe
{
    OwnedNode node;
    node.id = 90;
    node.metadata.hasVersion = true;
    node.metadata.versionNumber = 1;
    node.location = LocationView(10, 10);

    auto store = new OsmStore();
    OsmHandle originalHandle;
    StoreStatus storeStatus;
    assert(store.add(node, originalHandle, storeStatus));

    AuthoritativeBatch deletedBatch;
    deletedBatch.nodes ~= NodeState.absent(90, 2);

    ReconcileResult result;
    ReconcileStatus status;
    assert(reconcileAuthoritative(
        store,
        deletedBatch,
        result,
        status));
    assert(result.removed == 1);

    StoreElementState state;
    assert(!store.state(originalHandle, state, storeStatus));

    auto revived = node.deepCopy();
    revived.metadata.versionNumber = 3;
    revived.location = LocationView(11, 10);

    AuthoritativeBatch revivedBatch;
    revivedBatch.nodes ~= NodeState.present(revived);
    assert(reconcileAuthoritative(
        store,
        revivedBatch,
        result,
        status));
    assert(result.refreshed == 1);
    assert(result.conflicts == 0);

    OsmHandle revivedHandle;
    assert(store.find(ElementType.node, 90, revivedHandle));
    assert(revivedHandle != originalHandle);

    OwnedNode current;
    assert(store.copyNode(revivedHandle, current, storeStatus));
    assert(current.metadata.versionNumber == 3);
    assert(current.location.latitudeNanodegrees == 11);

    OwnedChangeSequence changes;
    assert(store.collectChanges(changes, storeStatus));
    assert(changes.entries.length == 0);
}
