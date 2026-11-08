module app;

import osm.model.change :
    ChangeAction,
    OwnedChangeEntry,
    OwnedChangeSequence;
import osm.model.owned :
    OwnedMetadata,
    OwnedNode,
    OwnedNodeRef,
    OwnedRelation,
    OwnedRelationMember,
    OwnedTag,
    OwnedWay,
    ownBytes;
import osm.osmchange :
    OsmChangeDocument;
import osm.replication;
import osm.store;
import osm.view.element :
    ElementType;
import osm.view.location :
    LocationView;
import transport.source :
    MemorySource;

@safe void main()
{
    qualifyStateAndPaths();
    qualifyContinuity();
    qualifyApplyAndRestartReplay();
    qualifyMultipleVersionsAndStaleInput();
    qualifyFailuresArePreflighted();
    qualifyLocalConflictIsNonMutating();
    qualifyCreateDeleteAndReferences();
}

private void qualifyStateAndPaths() @safe
{
    ReplicationState state;
    ReplicationStateReadStatus status;

    auto minimal = new MemorySource(
        cast(const(ubyte)[]) import("replication/state-minimal.txt"));
    assert(readReplicationState(minimal, state, status));
    assert(state.sequenceNumber == 123456);
    assert(state.timestamp.isoUtc == "2026-11-08T15:40:00Z");

    auto extra = new MemorySource(
        cast(const(ubyte)[])
            import("replication/state-extra-generator-fields.txt"));
    assert(readReplicationState(extra, state, status));
    assert(state.sequenceNumber == 123457);

    auto duplicate = new MemorySource(
        cast(const(ubyte)[])
            import("replication/state-duplicate-sequence.txt"));
    assert(!readReplicationState(duplicate, state, status));
    assert(status.error ==
        ReplicationStateReadError.duplicateSequence);

    auto malformed = new MemorySource(
        cast(const(ubyte)[])
            import("replication/state-malformed-timestamp.txt"));
    assert(!readReplicationState(malformed, state, status));
    assert(status.error ==
        ReplicationStateReadError.invalidTimestamp);

    ReplicationResourcePaths paths;
    ReplicationPathStatus pathStatus;
    assert(replicationResourcePaths(51_123, paths, pathStatus));
    assert(paths.change == "000/051/123.osc.gz");
    assert(paths.state == "000/051/123.state.txt");

    assert(!replicationResourcePaths(
        maximumReplicationSequence + 1,
        paths,
        pathStatus));
    assert(pathStatus.error ==
        ReplicationPathError.sequenceOutOfRange);
}

private void qualifyContinuity() @safe
{
    auto feed = makeFeed("official-minute", ReplicationGranularity.minute);
    auto otherFeed = makeFeed("mirror-minute", ReplicationGranularity.minute);

    auto current = readState(import("replication/state-minimal.txt"));
    auto next = readState(import("replication/state-next.txt"));
    auto gap = readState(import("replication/state-gap.txt"));

    ReplicationCheckpoint checkpoint;
    checkpoint.feed = feed;
    checkpoint.state = current;

    assert(classifyReplicationStep(checkpoint, feed, next) ==
        ReplicationStepRelation.next);
    assert(classifyReplicationStep(checkpoint, feed, current) ==
        ReplicationStepRelation.replay);
    assert(classifyReplicationStep(checkpoint, otherFeed, next) ==
        ReplicationStepRelation.feedMismatch);
    assert(classifyReplicationStep(checkpoint, feed, gap) ==
        ReplicationStepRelation.gap);

    auto stale = current;
    stale.sequenceNumber = current.sequenceNumber - 1;
    assert(classifyReplicationStep(checkpoint, feed, stale) ==
        ReplicationStepRelation.stale);

    auto mismatchedSame = current;
    mismatchedSame.timestamp =
        ReplicationTimestamp.fromUnixSeconds(
            current.timestamp.unixSeconds + 1);
    mismatchedSame.timestamp.isoUtc =
        "2026-11-08T15:40:01Z";
    assert(classifyReplicationStep(checkpoint, feed, mismatchedSame) ==
        ReplicationStepRelation.stateMismatch);
}

private void qualifyApplyAndRestartReplay() @safe
{
    auto feed = makeFeed("official-minute", ReplicationGranularity.minute);
    auto baseState = readState(import("replication/state-minimal.txt"));
    auto nextState = readState(import("replication/state-next.txt"));
    auto checkpoint = makeCheckpoint(feed, baseState);

    auto store = new OsmStore();
    auto base = node(1, 1, 10, "base");
    OsmHandle handle;
    StoreStatus storeStatus;
    assert(store.add(base, handle, storeStatus));

    auto v2 = node(1, 2, 20, "remote");
    OsmChangeDocument document;
    document.changes.entries ~=
        OwnedChangeEntry.fromNode(ChangeAction.modify, v2);

    ReplicationApplyResult result;
    ReplicationApplyStatus status;
    assert(applyReplicationStep(
        store,
        checkpoint,
        feed,
        nextState,
        document,
        result,
        status));
    assert(result.checkpointAdvanced);
    assert(result.checkpoint.state.sequenceNumber ==
        nextState.sequenceNumber);
    assert(result.stagedTransitions == 1);
    assert(result.replayedEntries == 0);

    OwnedNode current;
    assert(store.copyNode(handle, current, storeStatus));
    assert(current.metadata.versionNumber == 2);
    assert(current.location.latitudeNanodegrees == 20);

    // Simulate: store mutation completed, but the application crashed before
    // persisting the returned checkpoint. Replaying the same next sequence
    // against the old checkpoint is idempotent and advances the checkpoint.
    ReplicationApplyResult replay;
    assert(applyReplicationStep(
        store,
        checkpoint,
        feed,
        nextState,
        document,
        replay,
        status));
    assert(replay.checkpointAdvanced);
    assert(replay.replayedEntries == 1);
    assert(replay.stagedTransitions == 0);

    assert(store.copyNode(handle, current, storeStatus));
    assert(current.metadata.versionNumber == 2);

    // Once the caller persisted the new checkpoint, that state is a direct
    // sequence replay and does not even need to re-apply document contents.
    ReplicationApplyResult sameSequence;
    assert(applyReplicationStep(
        store,
        replay.checkpoint,
        feed,
        nextState,
        document,
        sameSequence,
        status));
    assert(sameSequence.sequenceReplay);
    assert(!sameSequence.checkpointAdvanced);
}

private void qualifyMultipleVersionsAndStaleInput() @safe
{
    auto feed = makeFeed("official-hour", ReplicationGranularity.hour);
    auto baseState = syntheticState(10, "2026-11-08T10:00:00Z", 1_762_596_000);
    auto nextState = syntheticState(11, "2026-11-08T11:00:00Z", 1_762_599_600);
    auto checkpoint = makeCheckpoint(feed, baseState);

    auto store = new OsmStore();
    auto v1 = node(2, 1, 100, "v1");
    OsmHandle handle;
    StoreStatus storeStatus;
    assert(store.add(v1, handle, storeStatus));

    auto v2 = node(2, 2, 200, "v2");
    auto v3 = node(2, 3, 300, "v3");

    // Deliberately reverse source order. M19 validates the identity's version
    // chain rather than assuming osmChange action-group order is chronological.
    OsmChangeDocument document;
    document.changes.entries ~=
        OwnedChangeEntry.fromNode(ChangeAction.modify, v3);
    document.changes.entries ~=
        OwnedChangeEntry.fromNode(ChangeAction.modify, v2);

    ReplicationApplyResult result;
    ReplicationApplyStatus status;
    assert(applyReplicationStep(
        store,
        checkpoint,
        feed,
        nextState,
        document,
        result,
        status));
    assert(result.stagedTransitions == 2);

    OwnedNode current;
    assert(store.copyNode(handle, current, storeStatus));
    assert(current.metadata.versionNumber == 3);

    // A next feed sequence may contain an older object version because feed
    // timestamps overlap. It is stale object data, not a store rollback.
    auto state12 = syntheticState(
        12,
        "2026-11-08T12:00:00Z",
        1_762_603_200);
    auto checkpoint11 = result.checkpoint;

    OsmChangeDocument staleDocument;
    staleDocument.changes.entries ~=
        OwnedChangeEntry.fromNode(ChangeAction.modify, v2);

    ReplicationApplyResult staleResult;
    assert(applyReplicationStep(
        store,
        checkpoint11,
        feed,
        state12,
        staleDocument,
        staleResult,
        status));
    assert(staleResult.staleEntries == 1);
    assert(staleResult.checkpointAdvanced);

    assert(store.copyNode(handle, current, storeStatus));
    assert(current.metadata.versionNumber == 3);
}

private void qualifyFailuresArePreflighted() @safe
{
    auto feed = makeFeed("official-day", ReplicationGranularity.day);
    auto state20 = syntheticState(20, "2026-11-08T00:00:00Z", 1_762_560_000);
    auto state21 = syntheticState(21, "2026-11-09T00:00:00Z", 1_762_646_400);
    auto checkpoint = makeCheckpoint(feed, state20);

    auto store = new OsmStore();
    auto a1 = node(10, 1, 10, "a1");
    auto b1 = node(11, 1, 11, "b1");
    OsmHandle aHandle;
    OsmHandle bHandle;
    StoreStatus storeStatus;
    assert(store.add(a1, aHandle, storeStatus));
    assert(store.add(b1, bHandle, storeStatus));

    auto a2 = node(10, 2, 20, "a2");
    auto b3 = node(11, 3, 30, "b3");

    OsmChangeDocument document;
    document.changes.entries ~=
        OwnedChangeEntry.fromNode(ChangeAction.modify, a2);
    document.changes.entries ~=
        OwnedChangeEntry.fromNode(ChangeAction.modify, b3);

    ReplicationApplyResult result;
    ReplicationApplyStatus status;
    assert(!applyReplicationStep(
        store,
        checkpoint,
        feed,
        state21,
        document,
        result,
        status));
    assert(status.error == ReplicationApplyError.versionGap);
    assert(!result.checkpointAdvanced);
    assert(result.checkpoint.state.sequenceNumber == 20);

    // The valid first identity was only staged. The later gap prevented every
    // visible store mutation.
    OwnedNode current;
    assert(store.copyNode(aHandle, current, storeStatus));
    assert(current.metadata.versionNumber == 1);
    assert(current.location.latitudeNanodegrees == 10);

    // Same version with a different payload is an integrity failure.
    auto mismatched = node(10, 1, 999, "not-a-replay");
    OsmChangeDocument mismatchDocument;
    mismatchDocument.changes.entries ~=
        OwnedChangeEntry.fromNode(ChangeAction.modify, mismatched);

    assert(!applyReplicationStep(
        store,
        checkpoint,
        feed,
        state21,
        mismatchDocument,
        result,
        status));
    assert(status.error == ReplicationApplyError.payloadMismatch);

    // A modification cannot invent an unknown baseline.
    auto unknown = node(999, 2, 1, "unknown");
    OsmChangeDocument unknownDocument;
    unknownDocument.changes.entries ~=
        OwnedChangeEntry.fromNode(ChangeAction.modify, unknown);

    assert(!applyReplicationStep(
        store,
        checkpoint,
        feed,
        state21,
        unknownDocument,
        result,
        status));
    assert(status.error == ReplicationApplyError.unknownBaseline);
}

private void qualifyLocalConflictIsNonMutating() @safe
{
    auto feed = makeFeed("official-minute", ReplicationGranularity.minute);
    auto state30 = syntheticState(30, "2026-11-08T15:30:00Z", 1_762_615_800);
    auto state31 = syntheticState(31, "2026-11-08T15:31:00Z", 1_762_615_860);
    auto checkpoint = makeCheckpoint(feed, state30);

    auto store = new OsmStore();
    auto base = node(20, 1, 100, "base");
    OsmHandle handle;
    StoreStatus storeStatus;
    assert(store.add(base, handle, storeStatus));

    auto local = base.deepCopy();
    local.tags[0].value =
        ownBytes(cast(const(ubyte)[])"local");
    assert(store.replace(handle, local, storeStatus));

    auto remote = base.deepCopy();
    remote.metadata.versionNumber = 2;
    remote.tags[0].value =
        ownBytes(cast(const(ubyte)[])"remote");

    OsmChangeDocument document;
    document.changes.entries ~=
        OwnedChangeEntry.fromNode(ChangeAction.modify, remote);

    ReplicationApplyResult result;
    ReplicationApplyStatus status;
    assert(!applyReplicationStep(
        store,
        checkpoint,
        feed,
        state31,
        document,
        result,
        status));
    assert(status.error == ReplicationApplyError.localConflict);
    assert(result.conflicts.length == 1);
    assert(!result.checkpointAdvanced);

    OwnedNode current;
    assert(store.copyNode(handle, current, storeStatus));
    assert(current.metadata.versionNumber == 1);
    assert(current.tags[0].value ==
        cast(const(ubyte)[])"local");
}

private void qualifyCreateDeleteAndReferences() @safe
{
    auto feed = makeFeed("official-minute", ReplicationGranularity.minute);
    auto state40 = syntheticState(40, "2026-11-08T16:00:00Z", 1_762_617_600);
    auto state41 = syntheticState(41, "2026-11-08T16:01:00Z", 1_762_617_660);
    auto checkpoint = makeCheckpoint(feed, state40);

    auto store = new OsmStore();

    auto n1 = node(30, 1, 300, "created");

    OwnedWay w1;
    w1.id = 31;
    w1.metadata.hasVersion = true;
    w1.metadata.versionNumber = 1;
    OwnedNodeRef nodeRef;
    nodeRef.id = 30;
    w1.nodes ~= nodeRef;

    OwnedRelation r1;
    r1.id = 32;
    r1.metadata.hasVersion = true;
    r1.metadata.versionNumber = 1;
    OwnedRelationMember member;
    member.type = ElementType.way;
    member.id = 31;
    member.role = ownBytes(cast(const(ubyte)[])"outer");
    r1.members ~= member;

    OsmChangeDocument createDocument;
    createDocument.changes.entries ~=
        OwnedChangeEntry.fromNode(ChangeAction.create, n1);
    createDocument.changes.entries ~=
        OwnedChangeEntry.fromWay(ChangeAction.create, w1);
    createDocument.changes.entries ~=
        OwnedChangeEntry.fromRelation(ChangeAction.create, r1);

    ReplicationApplyResult result;
    ReplicationApplyStatus status;
    assert(applyReplicationStep(
        store,
        checkpoint,
        feed,
        state41,
        createDocument,
        result,
        status));
    assert(result.reconciliation.inserted == 3);

    StoreNodeView nodeView;
    StoreWayView wayView;
    StoreRelationView relationView;
    StoreStatus storeStatus;
    assert(store.node(30, nodeView, storeStatus));
    assert(store.way(31, wayView, storeStatus));
    assert(store.relation(32, relationView, storeStatus));

    // Next step deletes the Node at version 2. The authoritative tombstone is
    // retained for later replay/version continuity and is not a local upload.
    auto state42 = syntheticState(42, "2026-11-08T16:02:00Z", 1_762_617_720);
    OwnedMetadata deletedMetadata;
    deletedMetadata.hasVersion = true;
    deletedMetadata.versionNumber = 2;
    deletedMetadata.hasVisibility = true;
    deletedMetadata.visible = false;

    OsmChangeDocument deleteDocument;
    deleteDocument.changes.entries ~=
        OwnedChangeEntry.deletion(
            ElementType.node,
            30,
            deletedMetadata);

    ReplicationApplyResult deleted;
    assert(applyReplicationStep(
        store,
        result.checkpoint,
        feed,
        state42,
        deleteDocument,
        deleted,
        status));
    assert(deleted.reconciliation.removed == 1);

    OsmHandle found;
    assert(!store.find(ElementType.node, 30, found));

    OwnedChangeSequence localChanges;
    assert(store.collectChanges(localChanges, storeStatus));
    assert(localChanges.empty);
}

private ReplicationFeed makeFeed(
    string id,
    ReplicationGranularity granularity) @safe
{
    ReplicationFeed feed;
    assert(ReplicationFeed.create(id, granularity, feed));
    return feed;
}

private ReplicationCheckpoint makeCheckpoint(
    ReplicationFeed feed,
    ReplicationState state) @safe
{
    ReplicationCheckpoint checkpoint;
    checkpoint.feed = feed;
    checkpoint.state = state;
    assert(checkpoint.valid);
    return checkpoint;
}

private ReplicationState readState(string text) @safe
{
    auto source = new MemorySource(cast(const(ubyte)[]) text);
    ReplicationState state;
    ReplicationStateReadStatus status;
    assert(readReplicationState(source, state, status));
    return state;
}

private ReplicationState syntheticState(
    ulong sequence,
    string isoUtc,
    long unixSeconds) @safe
{
    ReplicationState result;
    result.sequenceNumber = sequence;
    result.timestamp = ReplicationTimestamp.fromUnixSeconds(unixSeconds);
    result.timestamp.isoUtc = isoUtc;
    assert(result.valid);
    return result;
}

private OwnedNode node(
    long id,
    int versionNumber,
    long latitude,
    string value) @safe
{
    OwnedNode result;
    result.id = id;
    result.metadata.hasVersion = true;
    result.metadata.versionNumber = versionNumber;
    result.metadata.hasVisibility = true;
    result.metadata.visible = true;
    result.location = LocationView(latitude, 16_000_000_000L);
    result.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[]) value));
    return result;
}
