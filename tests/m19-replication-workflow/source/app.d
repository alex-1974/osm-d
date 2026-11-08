module app;

import compression.core : DecodeStatus;
import compression.encode :
    encodeGzipStored,
    gzipStoredSize;
import osm.model.owned :
    OwnedMetadata,
    OwnedNode,
    OwnedNodeRef,
    OwnedRelation,
    OwnedRelationMember,
    OwnedTag,
    OwnedWay,
    ownBytes;
import osm.replication;
import osm.store;
import osm.view.element : ElementType;
import osm.view.location : LocationView;
import std.format : format;
import transport.source : MemorySource;

@safe void main()
{
    qualifyMultiSequenceWorkflow();
    qualifyLocalConflictHandoff();
}

private void qualifyMultiSequenceWorkflow() @safe
{
    auto feed = makeFeed();
    auto state100 = readState(import("replication/workflow/state-100.txt"));
    auto state101 = readState(import("replication/workflow/state-101.txt"));
    auto state102 = readState(import("replication/workflow/state-102.txt"));
    auto state103 = readState(import("replication/workflow/state-103.txt"));
    auto state104 = readState(import("replication/workflow/state-104.txt"));

    // Sequence continuity is authoritative even when adjacent state timestamps
    // overlap exactly.
    assert(state101.timestamp.unixSeconds ==
        state102.timestamp.unixSeconds);

    auto checkpoint = makeCheckpoint(feed, state100);
    auto store = baselineStore();

    auto options = ingestOptions();
    ReplicationApplyResult result;
    ReplicationIngestStatus status;

    // 100 -> 101: create Node 3 and update Node/Way/Relation.
    assert(applyFixture(
        store,
        checkpoint,
        feed,
        state101,
        import("replication/workflow/101.osc"),
        options,
        result,
        status));
    assert(result.checkpointAdvanced);
    assert(result.inputEntries == 4);
    assert(result.stagedTransitions == 4);
    checkpoint = result.checkpoint;
    assert(checkpoint.state.sequenceNumber == 101);
    assertParentIndexesAfter101(store);

    // 101 -> 102: two contiguous versions of Node 1 are deliberately authored
    // in reverse XML order. M19 sorts the version chain before mutation.
    const checkpoint101 = checkpoint;
    assert(applyFixture(
        store,
        checkpoint,
        feed,
        state102,
        import("replication/workflow/102.osc"),
        options,
        result,
        status));
    assert(result.checkpointAdvanced);
    assert(result.stagedTransitions == 4);
    checkpoint = result.checkpoint;
    assert(checkpoint.state.sequenceNumber == 102);
    assertNodeVersion(store, 1, 4);

    // Crash window: the store reached sequence 102, but persistence retained
    // checkpoint 101. Re-applying the same compressed resource is idempotent
    // and returns the missing checkpoint advance.
    ReplicationApplyResult restart;
    assert(applyFixture(
        store,
        checkpoint101,
        feed,
        state102,
        import("replication/workflow/102.osc"),
        options,
        restart,
        status));
    assert(restart.checkpointAdvanced);
    assert(restart.replayedEntries == 3);
    assert(restart.staleEntries == 1);
    assert(restart.stagedTransitions == 0);
    assert(restart.checkpoint.state.sequenceNumber == 102);
    assertNodeVersion(store, 1, 4);

    // With the persisted checkpoint already at 102, the same sequence is a
    // direct sequence replay and does not mutate the store.
    ReplicationApplyResult sameSequence;
    assert(applyFixture(
        store,
        restart.checkpoint,
        feed,
        state102,
        import("replication/workflow/102.osc"),
        options,
        sameSequence,
        status));
    assert(sameSequence.sequenceReplay);
    assert(!sameSequence.checkpointAdvanced);
    assertNodeVersion(store, 1, 4);

    // A valid resource for 104 cannot skip sequence 103.
    const beforeGap = semanticFingerprint(store);
    assert(!applyFixture(
        store,
        checkpoint,
        feed,
        state104,
        import("replication/workflow/104.osc"),
        options,
        result,
        status));
    assert(status.error == ReplicationIngestError.applyFailure);
    assert(status.applyStatus.error == ReplicationApplyError.sequenceGap);
    assert(result.checkpoint.state.sequenceNumber == 102);
    assert(semanticFingerprint(store) == beforeGap);

    // 102 -> 103 exercises create/delete plus Way/Relation reference updates.
    assert(applyFixture(
        store,
        checkpoint,
        feed,
        state103,
        import("replication/workflow/103.osc"),
        options,
        result,
        status));
    checkpoint = result.checkpoint;
    assert(checkpoint.state.sequenceNumber == 103);
    assertParentIndexesAfter103(store);

    // Corruption and truncation fail before semantic apply and preserve both
    // store state and caller-owned checkpoint.
    const beforeFailure = semanticFingerprint(store);
    auto valid104 = gzip(import("replication/workflow/104.osc"));

    auto corrupt = valid104.dup;
    corrupt[$ - 8] ^= 0x01;
    auto corruptSource = new MemorySource(corrupt);
    assert(!applyGzipReplicationStep(
        store,
        corruptSource,
        checkpoint,
        feed,
        state104,
        result,
        status,
        options));
    assert(status.error == ReplicationIngestError.compressionFailure);
    assert(result.checkpoint.state.sequenceNumber == 103);
    assert(semanticFingerprint(store) == beforeFailure);

    auto truncatedSource = new MemorySource(valid104[0 .. $ - 3]);
    assert(!applyGzipReplicationStep(
        store,
        truncatedSource,
        checkpoint,
        feed,
        state104,
        result,
        status,
        options));
    assert(status.error == ReplicationIngestError.compressionFailure);
    assert(result.checkpoint.state.sequenceNumber == 103);
    assert(semanticFingerprint(store) == beforeFailure);

    // 103 -> 104 contains an already-known Node 3 version alongside ordinary
    // authoritative changes. The duplicate is replay, not a rollback.
    assert(applyFixture(
        store,
        checkpoint,
        feed,
        state104,
        import("replication/workflow/104.osc"),
        options,
        result,
        status));
    checkpoint = result.checkpoint;
    assert(checkpoint.state.sequenceNumber == 104);
    assert(result.replayedEntries == 1);
    assert(result.stagedTransitions == 2);

    verifyExpectedFinalSnapshot(store);
}

private void qualifyLocalConflictHandoff() @safe
{
    auto feed = makeFeed();
    auto state100 = readState(import("replication/workflow/state-100.txt"));
    auto state101 = readState(import("replication/workflow/state-101.txt"));
    auto state102 = readState(import("replication/workflow/state-102.txt"));
    auto state103 = readState(import("replication/workflow/state-103.txt"));
    auto state104 = readState(import("replication/workflow/state-104.txt"));

    auto checkpoint = makeCheckpoint(feed, state100);
    auto store = baselineStore();
    auto options = ingestOptions();

    ReplicationApplyResult result;
    ReplicationIngestStatus status;

    const states = [state101, state102, state103];
    const fixtures = [
        import("replication/workflow/101.osc"),
        import("replication/workflow/102.osc"),
        import("replication/workflow/103.osc")
    ];

    foreach (i; 0 .. states.length)
    {
        auto state = states[i];
        assert(applyFixture(
            store,
            checkpoint,
            feed,
            state,
            fixtures[i],
            options,
            result,
            status));
        checkpoint = result.checkpoint;
    }

    OsmHandle nodeHandle;
    assert(store.find(ElementType.node, 1, nodeHandle));

    StoreStatus storeStatus;
    OwnedNode local;
    assert(store.copyNode(nodeHandle, local, storeStatus));
    local.tags[0].value =
        ownBytes(cast(const(ubyte)[]) "local-alpha");
    assert(store.replace(nodeHandle, local, storeStatus));

    const before = semanticFingerprint(store);
    assert(!applyFixture(
        store,
        checkpoint,
        feed,
        state104,
        import("replication/workflow/104.osc"),
        options,
        result,
        status));
    assert(status.error == ReplicationIngestError.applyFailure);
    assert(status.applyStatus.error == ReplicationApplyError.localConflict);
    assert(result.conflicts.length == 1);
    assert(!result.checkpointAdvanced);
    assert(result.checkpoint.state.sequenceNumber == 103);
    assert(semanticFingerprint(store) == before);

    // Once local work is resolved, replaying the same sequence succeeds.
    assert(store.revert(nodeHandle, storeStatus));
    assert(applyFixture(
        store,
        checkpoint,
        feed,
        state104,
        import("replication/workflow/104.osc"),
        options,
        result,
        status));
    assert(result.checkpoint.state.sequenceNumber == 104);
    verifyExpectedFinalSnapshot(store);
}

private bool applyFixture(
    OsmStore store,
    scope ref const ReplicationCheckpoint checkpoint,
    scope ref const ReplicationFeed feed,
    scope ref const ReplicationState state,
    string xml,
    ReplicationIngestOptions options,
    out ReplicationApplyResult result,
    out ReplicationIngestStatus status) @safe
{
    auto encoded = gzip(xml);
    auto source = new MemorySource(encoded);
    const accepted = applyGzipReplicationStep(
        store,
        source,
        checkpoint,
        feed,
        state,
        result,
        status,
        options);

    if (!accepted)
    {
        // Keep CI diagnostics useful without changing the public error model.
        import std.stdio : stderr;
        stderr.writefln(
            "M19 fixture rejected seq=%s stage=%s transport=%s compression=%s xml=%s apply=%s compressed=%s decoded=%s",
            state.sequenceNumber,
            status.error,
            status.transportError,
            status.compressionError.code,
            status.osmChangeStatus.error,
            status.applyStatus.error,
            status.compressedBytesRead,
            status.decodedBytes);
    }

    return accepted;
}

private ubyte[] gzip(string xml) @safe
{
    const input = cast(const(ubyte)[]) xml;
    auto encoded = new ubyte[gzipStoredSize(input.length)];
    auto result = encodeGzipStored(input, encoded);
    assert(result.status == DecodeStatus.done);
    encoded.length = result.produced;
    return encoded;
}

private ReplicationIngestOptions ingestOptions() @safe pure nothrow @nogc
{
    ReplicationIngestOptions result;
    result.compressedBufferSize = 23;
    result.maximumCompressedBytes = 16 * 1024;
    result.maximumDecodedBytes = 16 * 1024;
    result.maximumExpansionRatio = 128;
    result.osmChange.bufferSize = 31;
    result.osmChange.maximumChildrenPerElement = 1024;
    result.osmChange.maximumXmlDeclarationBytes = 256;
    return result;
}

private OsmStore baselineStore() @safe
{
    auto store = new OsmStore();
    StoreStatus status;
    OsmHandle ignored;

    OwnedNode n1;
    n1.id = 1;
    n1.metadata = metadata(1);
    n1.location = LocationView(48_100_000_000L, 16_100_000_000L);
    n1.tags ~= tag("name", "alpha");
    assert(store.add(n1, ignored, status));

    OwnedNode n2;
    n2.id = 2;
    n2.metadata = metadata(1);
    n2.location = LocationView(48_100_200_000L, 16_100_200_000L);
    n2.tags ~= tag("name", "beta");
    assert(store.add(n2, ignored, status));

    OwnedWay way;
    way.id = 10;
    way.metadata = metadata(1);
    way.nodes ~= nodeRef(1);
    way.nodes ~= nodeRef(2);
    way.tags ~= tag("highway", "residential");
    assert(store.add(way, ignored, status));

    OwnedRelation relation;
    relation.id = 20;
    relation.metadata = metadata(1);
    relation.members ~= member(ElementType.way, 10, "outer");
    relation.members ~= member(ElementType.node, 2, "label");
    relation.tags ~= tag("type", "multipolygon");
    assert(store.add(relation, ignored, status));

    return store;
}

private void assertParentIndexesAfter101(OsmStore store) @safe
{
    assert(store.parentWays(2).empty);

    auto p3 = store.parentWays(3);
    assert(!p3.empty);
    assert(p3.front.id == 10);
    p3.popFront();
    assert(p3.empty);

    auto r3 = store.parentRelations(ElementType.node, 3);
    assert(!r3.empty);
    assert(r3.front.id == 20);
    r3.popFront();
    assert(r3.empty);
}

private void assertParentIndexesAfter103(OsmStore store) @safe
{
    OsmHandle ignored;
    assert(!store.find(ElementType.node, 2, ignored));
    assert(store.parentWays(1).empty);
    assert(store.parentWays(2).empty);

    auto p3 = store.parentWays(3);
    assert(!p3.empty && p3.front.id == 10);
    p3.popFront();
    assert(p3.empty);

    auto p4 = store.parentWays(4);
    assert(!p4.empty && p4.front.id == 10);
    p4.popFront();
    assert(p4.empty);

    auto r4 = store.parentRelations(ElementType.node, 4);
    assert(!r4.empty && r4.front.id == 20);
    r4.popFront();
    assert(r4.empty);
}

private void verifyExpectedFinalSnapshot(OsmStore store) @safe
{
    const counts = store.counts;
    assert(counts.liveNodes == 3);
    assert(counts.liveWays == 1);
    assert(counts.liveRelations == 1);

    assertNodeVersion(store, 1, 5);
    assertNodeVersion(store, 3, 1);
    assertNodeVersion(store, 4, 1);

    OsmHandle ignored;
    assert(!store.find(ElementType.node, 2, ignored));

    StoreStatus status;
    StoreWayView way;
    assert(store.way(10, way, status));
    assert(way.metadata.versionNumber == 4);
    auto refs = way.nodes;
    assert(!refs.empty && refs.front.id == 3);
    refs.popFront();
    assert(!refs.empty && refs.front.id == 4);
    refs.popFront();
    assert(refs.empty);

    StoreRelationView relation;
    assert(store.relation(20, relation, status));
    assert(relation.metadata.versionNumber == 5);
    auto members = relation.members;
    assert(!members.empty);
    assert(members.front.type == ElementType.way);
    assert(members.front.id == 10);
    members.popFront();
    assert(!members.empty);
    assert(members.front.type == ElementType.node);
    assert(members.front.id == 1);
    members.popFront();
    assert(members.empty);

    auto wayParent3 = store.parentWays(3);
    assert(!wayParent3.empty && wayParent3.front.id == 10);
    auto wayParent4 = store.parentWays(4);
    assert(!wayParent4.empty && wayParent4.front.id == 10);
    assert(store.parentWays(1).empty);

    auto relationParentWay =
        store.parentRelations(ElementType.way, 10);
    assert(!relationParentWay.empty &&
        relationParentWay.front.id == 20);

    auto relationParentNode =
        store.parentRelations(ElementType.node, 1);
    assert(!relationParentNode.empty &&
        relationParentNode.front.id == 20);

    assert(store.parentRelations(ElementType.node, 4).empty);

    // Authored independent expected-state fingerprint.
    assert(semanticFingerprint(store) ==
        "nodes=1@5,3@1,4@1;way=10@4[3,4];relation=20@5[way:10,node:1]");
}

private string semanticFingerprint(OsmStore store) @safe
{
    import std.array : appender;

    auto fingerprint = appender!string();
    fingerprint.put("nodes=");

    bool first;
    auto nodes = store.nodes;
    while (!nodes.empty)
    {
        if (first)
            fingerprint.put(",");
        first = true;
        fingerprint.put(format("%s@%s", nodes.front.id, nodes.front.metadata.versionNumber));
        nodes.popFront();
    }

    fingerprint.put(";way=");
    auto ways = store.ways;
    while (!ways.empty)
    {
        auto way = ways.front;
        fingerprint.put(format("%s@%s[", way.id, way.metadata.versionNumber));
        auto refs = way.nodes;
        bool refFirst;
        while (!refs.empty)
        {
            if (refFirst)
                fingerprint.put(",");
            refFirst = true;
            fingerprint.put(format("%s", refs.front.id));
            refs.popFront();
        }
        fingerprint.put("]");
        ways.popFront();
    }

    fingerprint.put(";relation=");
    auto relations = store.relations;
    while (!relations.empty)
    {
        auto relation = relations.front;
        fingerprint.put(format("%s@%s[", relation.id, relation.metadata.versionNumber));
        auto members = relation.members;
        bool memberFirst;
        while (!members.empty)
        {
            if (memberFirst)
                fingerprint.put(",");
            memberFirst = true;
            const kind = members.front.type == ElementType.node
                ? "node"
                : members.front.type == ElementType.way
                    ? "way"
                    : "relation";
            fingerprint.put(format("%s:%s", kind, members.front.id));
            members.popFront();
        }
        fingerprint.put("]");
        relations.popFront();
    }

    return fingerprint.data;
}

private void assertNodeVersion(
    OsmStore store,
    long id,
    int versionNumber) @safe
{
    StoreStatus status;
    StoreNodeView node;
    assert(store.node(id, node, status));
    assert(node.metadata.versionNumber == versionNumber);
}

private ReplicationFeed makeFeed() @safe
{
    ReplicationFeed feed;
    assert(ReplicationFeed.create(
        "m19-authored-minute",
        ReplicationGranularity.minute,
        feed));
    return feed;
}

private ReplicationCheckpoint makeCheckpoint(
    ReplicationFeed feed,
    ReplicationState state) @safe
{
    ReplicationCheckpoint result;
    result.feed = feed;
    result.state = state;
    assert(result.valid);
    return result;
}

private ReplicationState readState(string text) @safe
{
    auto source = new MemorySource(cast(const(ubyte)[]) text);
    ReplicationState state;
    ReplicationStateReadStatus status;
    assert(readReplicationState(source, state, status));
    return state;
}

private OwnedMetadata metadata(int versionNumber) @safe pure nothrow
{
    OwnedMetadata result;
    result.hasVersion = true;
    result.versionNumber = versionNumber;
    result.hasVisibility = true;
    result.visible = true;
    return result;
}

private OwnedTag tag(string key, string value) @safe
{
    return OwnedTag(
        ownBytes(cast(const(ubyte)[]) key),
        ownBytes(cast(const(ubyte)[]) value));
}

private OwnedNodeRef nodeRef(long id) @safe pure nothrow
{
    OwnedNodeRef result;
    result.id = id;
    return result;
}

private OwnedRelationMember member(
    ElementType type,
    long id,
    string role) @safe
{
    OwnedRelationMember result;
    result.type = type;
    result.id = id;
    result.role = ownBytes(cast(const(ubyte)[]) role);
    return result;
}
