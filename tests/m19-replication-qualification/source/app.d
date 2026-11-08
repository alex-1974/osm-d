module app;

import core.memory : GC;
import fixtures;
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
import osm.view.element :
    ElementType,
    OsmId;
import osm.view.location : LocationView;
import std.base64 : Base64;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writefln;
import transport.source : MemorySource;

private struct FixtureSet
{
    ubyte[] s1001;
    ubyte[] s1002;
    ubyte[] s1003;
    ubyte[] s1004;
    ubyte[] s1005;
}

private struct QualificationSummary
{
    size_t acceptedSequences;
    size_t replayedSequences;
    size_t rejectedSequences;
    size_t stagedTransitions;
    size_t replayedEntries;
    size_t staleEntries;
}

int main(string[] args)
{
    auto fixtures = decodeFixtures();
    qualifyCompleteWorkflow(fixtures);

    if (args.length == 2 && args[1] == "--measure")
        measureIncrementalWorkflow(fixtures);
    else if (args.length != 1)
        return 2;

    return 0;
}

private FixtureSet decodeFixtures()
{
    FixtureSet result;
    result.s1001 = Base64.decode(gzip1001Base64);
    result.s1002 = Base64.decode(gzip1002Base64);
    result.s1003 = Base64.decode(gzip1003Base64);
    result.s1004 = Base64.decode(gzip1004Base64);
    result.s1005 = Base64.decode(gzip1005Base64);
    return result;
}

private void qualifyCompleteWorkflow(ref const FixtureSet fixtures)
{
    auto feed = makeFeed();
    auto state1000 = state(1000, 1_762_617_600, "2026-11-08T16:00:00Z");
    auto state1001 = state(1001, 1_762_617_660, "2026-11-08T16:01:00Z");
    auto state1002 = state(1002, 1_762_617_720, "2026-11-08T16:02:00Z");
    // Deliberately overlap the prior feed timestamp. Sequence continuity, not
    // wall-clock arithmetic, defines the next replication step.
    auto state1003 = state(1003, 1_762_617_720, "2026-11-08T16:02:00Z");
    auto state1004 = state(1004, 1_762_617_780, "2026-11-08T16:03:00Z");
    auto state1005 = state(1005, 1_762_617_840, "2026-11-08T16:04:00Z");

    auto checkpoint1000 = checkpoint(feed, state1000);
    auto store = baselineStore();

    ReplicationApplyResult result;
    ReplicationIngestStatus status;
    auto options = ingestOptions();

    assert(applyFixture(
        store, fixtures.s1001, checkpoint1000, feed, state1001,
        result, status, options));
    assert(result.checkpointAdvanced);
    assert(result.stagedTransitions == 4);
    auto checkpoint1001 = result.checkpoint;
    qualifyIndexesAfter1001(store);

    assert(applyFixture(
        store, fixtures.s1002, checkpoint1001, feed, state1002,
        result, status, options));
    assert(result.checkpointAdvanced);
    assert(result.stagedTransitions == 4);
    auto checkpoint1002 = result.checkpoint;
    qualifyIndexesAfter1002(store);

    // Restart after store mutation but before durable checkpoint persistence:
    // replay the same resource against the old checkpoint.
    ReplicationApplyResult restartReplay;
    assert(applyFixture(
        store, fixtures.s1002, checkpoint1001, feed, state1002,
        restartReplay, status, options));
    assert(restartReplay.checkpointAdvanced);
    assert(restartReplay.replayedEntries == 4);
    assert(restartReplay.stagedTransitions == 0);
    assert(restartReplay.checkpoint.state.sequenceNumber == 1002);
    qualifyIndexesAfter1002(store);

    // Once checkpoint 1002 is durable, the same sequence is a direct sequence
    // replay and causes no store mutation.
    ReplicationApplyResult sequenceReplay;
    assert(applyFixture(
        store, fixtures.s1002, checkpoint1002, feed, state1002,
        sequenceReplay, status, options));
    assert(sequenceReplay.sequenceReplay);
    assert(!sequenceReplay.checkpointAdvanced);

    // An explicit sequence gap must fail before any semantic store update.
    auto node103VersionBeforeGap = nodeVersion(store, 103);
    assert(!applyFixture(
        store, fixtures.s1004, checkpoint1002, feed, state1004,
        result, status, options));
    assert(status.error == ReplicationIngestError.applyFailure);
    assert(status.applyStatus.error == ReplicationApplyError.sequenceGap);
    assert(result.checkpoint.state.sequenceNumber == 1002);
    assert(nodeVersion(store, 103) == node103VersionBeforeGap);

    // Sequence 1003 overlaps the prior timestamp and carries one exact
    // already-known version plus one new version.
    assert(applyFixture(
        store, fixtures.s1003, checkpoint1002, feed, state1003,
        result, status, options));
    assert(result.replayedEntries == 1);
    assert(result.stagedTransitions == 1);
    auto checkpoint1003 = result.checkpoint;

    // Corrupt/truncated transport cannot advance the checkpoint or mutate the
    // store. Retry of the complete resource must then succeed deterministically.
    auto node103VersionBeforeTruncation = nodeVersion(store, 103);
    auto truncated = fixtures.s1004[0 .. $ - 5];
    assert(!applyFixture(
        store, truncated, checkpoint1003, feed, state1004,
        result, status, options));
    assert(status.error == ReplicationIngestError.compressionFailure);
    assert(result.checkpoint.state.sequenceNumber == 1003);
    assert(nodeVersion(store, 103) == node103VersionBeforeTruncation);

    assert(applyFixture(
        store, fixtures.s1004, checkpoint1003, feed, state1004,
        result, status, options));
    assert(result.stagedTransitions == 2);
    auto checkpoint1004 = result.checkpoint;
    assert(!hasElement(store, ElementType.node, 101));

    // Dirty local edits hand off to M18 conflict semantics. The remote step
    // must be entirely non-mutating and leave the checkpoint at 1004.
    StoreStatus storeStatus;
    StoreNodeView node102View;
    assert(store.node(102, node102View, storeStatus));
    auto node102Handle = node102View.handle;
    OwnedNode local102;
    assert(store.copyNode(node102Handle, local102, storeStatus));
    local102.tags[0].value =
        ownBytes(cast(const(ubyte)[])"local-dirty");
    assert(store.replace(node102Handle, local102, storeStatus));

    assert(!applyFixture(
        store, fixtures.s1005, checkpoint1004, feed, state1005,
        result, status, options));
    assert(status.error == ReplicationIngestError.applyFailure);
    assert(status.applyStatus.error == ReplicationApplyError.localConflict);
    assert(result.checkpoint.state.sequenceNumber == 1004);
    assert(nodeVersion(store, 102) == 2);

    assert(store.revert(node102Handle, storeStatus));
    assert(applyFixture(
        store, fixtures.s1005, checkpoint1004, feed, state1005,
        result, status, options));
    assert(result.checkpoint.state.sequenceNumber == 1005);

    qualifyFinalSnapshot(store);
}

private void measureIncrementalWorkflow(ref const FixtureSet fixtures)
{
    enum size_t chainCount = 200;

    auto feed = makeFeed();
    auto state1000 = state(1000, 1_762_617_600, "2026-11-08T16:00:00Z");
    auto states = [
        state(1001, 1_762_617_660, "2026-11-08T16:01:00Z"),
        state(1002, 1_762_617_720, "2026-11-08T16:02:00Z"),
        state(1003, 1_762_617_720, "2026-11-08T16:02:00Z"),
        state(1004, 1_762_617_780, "2026-11-08T16:03:00Z"),
        state(1005, 1_762_617_840, "2026-11-08T16:04:00Z")
    ];
    const(ubyte)[][] payloads = [
        fixtures.s1001,
        fixtures.s1002,
        fixtures.s1003,
        fixtures.s1004,
        fixtures.s1005
    ];

    auto stores = new OsmStore[chainCount];
    auto checkpoints = new ReplicationCheckpoint[chainCount];
    foreach (i; 0 .. chainCount)
    {
        stores[i] = baselineStore();
        checkpoints[i] = checkpoint(feed, state1000);
    }

    auto options = ingestOptions();
    GC.collect();
    const allocatedBefore = GC.allocatedInCurrentThread();
    const profileBefore = GC.profileStats();

    StopWatch watch;
    watch.start();

    QualificationSummary summary;
    foreach (i; 0 .. chainCount)
    {
        foreach (step; 0 .. states.length)
        {
            ReplicationApplyResult result;
            ReplicationIngestStatus status;
            if (!applyFixture(
                    stores[i],
                    payloads[step],
                    checkpoints[i],
                    feed,
                    states[step],
                    result,
                    status,
                    options))
                throw new Exception("M19 measured replication step failed");

            checkpoints[i] = result.checkpoint;
            ++summary.acceptedSequences;
            summary.stagedTransitions += result.stagedTransitions;
            summary.replayedEntries += result.replayedEntries;
            summary.staleEntries += result.staleEntries;
        }
    }

    watch.stop();

    const profileAfter = GC.profileStats();
    const allocatedAfter = GC.allocatedInCurrentThread();

    const expectedSequences = chainCount * states.length;
    if (summary.acceptedSequences != expectedSequences ||
        summary.stagedTransitions != chainCount * 12 ||
        summary.replayedEntries != chainCount ||
        summary.staleEntries != 0)
        throw new Exception("unexpected M19 measured summary");

    foreach (i; 0 .. chainCount)
    {
        if (checkpoints[i].state.sequenceNumber != 1005)
            throw new Exception("measured chain checkpoint mismatch");
    }
    qualifyFinalSnapshot(stores[$ - 1]);

    const elapsedUs = watch.peek.total!"usecs";
    const sequencesPerSecond = elapsedUs == 0
        ? 0.0
        : cast(double)expectedSequences * 1_000_000.0 /
            cast(double)elapsedUs;

    writefln(
        "M19_REPLICATION_WORKLOAD chains=%s sequences=%s transitions=%s replayed_entries=%s elapsed_us=%s sequences_per_second=%.2f gc_allocated_bytes=%s gc_collections=%s",
        chainCount,
        expectedSequences,
        summary.stagedTransitions,
        summary.replayedEntries,
        elapsedUs,
        sequencesPerSecond,
        allocatedAfter - allocatedBefore,
        profileAfter.numCollections - profileBefore.numCollections);
}

private bool applyFixture(
    OsmStore store,
    scope const(ubyte)[] payload,
    scope ref const ReplicationCheckpoint current,
    scope ref const ReplicationFeed feed,
    scope ref const ReplicationState candidate,
    out ReplicationApplyResult result,
    out ReplicationIngestStatus status,
    ReplicationIngestOptions options)
{
    auto source = new MemorySource(payload);
    return applyGzipReplicationStep(
        store,
        source,
        current,
        feed,
        candidate,
        result,
        status,
        options);
}

private ReplicationIngestOptions ingestOptions()
{
    ReplicationIngestOptions result;
    result.compressedBufferSize = 17;
    result.maximumCompressedBytes = 4 * 1024;
    result.maximumDecodedBytes = 16 * 1024;
    result.maximumExpansionRatio = 128;
    result.osmChange.bufferSize = 31;
    return result;
}

private OsmStore baselineStore()
{
    auto store = new OsmStore();
    StoreStatus status;
    OsmHandle handle;

    auto n100 = node(100, 1, 48_000_000_100L, 16_000_000_100L, "n100-v1");
    auto n101 = node(101, 1, 48_000_000_101L, 16_000_000_101L, "n101-v1");
    auto n102 = node(102, 1, 48_000_000_102L, 16_000_000_102L, "n102-v1");
    assert(store.add(n100, handle, status));
    assert(store.add(n101, handle, status));
    assert(store.add(n102, handle, status));

    OwnedWay way;
    way.id = 200;
    way.metadata = metadata(1, true);
    way.nodes ~= nodeRef(100);
    way.nodes ~= nodeRef(101);
    way.tags ~= tag("highway", "service");
    assert(store.add(way, handle, status));

    OwnedRelation relation;
    relation.id = 300;
    relation.metadata = metadata(1, true);
    relation.members ~= member(ElementType.way, 200, "outer");
    relation.tags ~= tag("type", "multipolygon");
    assert(store.add(relation, handle, status));

    return store;
}

private void qualifyIndexesAfter1001(OsmStore store)
{
    assert(hasParentWay(store, 100, 200));
    assert(!hasParentWay(store, 101, 200));
    assert(hasParentWay(store, 102, 200));
    assert(parentWayCount(store, 102) == 1);

    assert(hasParentRelation(store, ElementType.way, 200, 300));
    assert(hasParentRelation(store, ElementType.node, 100, 300));
}

private void qualifyIndexesAfter1002(OsmStore store)
{
    assert(!hasParentWay(store, 100, 200));
    assert(parentWayCount(store, 102) == 2);
    assert(parentWayCount(store, 103) == 2);
    assert(hasParentWay(store, 102, 200));
    assert(hasParentWay(store, 102, 201));
    assert(hasParentWay(store, 103, 200));
    assert(hasParentWay(store, 103, 201));

    assert(hasParentRelation(store, ElementType.way, 200, 300));
    assert(hasParentRelation(store, ElementType.way, 201, 300));
    assert(hasParentRelation(store, ElementType.node, 103, 300));
    assert(!hasParentRelation(store, ElementType.node, 100, 300));
}

private void qualifyFinalSnapshot(OsmStore store)
{
    assertNode(store, 100, 3, 48_000_000_300L, "n100-v3");
    assertNode(store, 102, 3, 48_000_000_302L, "n102-v3");
    assertNode(store, 103, 2, 48_000_000_203L, "n103-v2");
    assert(!hasElement(store, ElementType.node, 101));

    StoreStatus status;
    StoreWayView way;
    assert(store.way(200, way, status));
    assert(way.metadata.versionNumber == 3);
    assertWayNodes(way, [102L, 103L]);

    assert(store.way(201, way, status));
    assert(way.metadata.versionNumber == 1);
    assertWayNodes(way, [102L, 103L]);

    StoreRelationView relation;
    assert(store.relation(300, relation, status));
    assert(relation.metadata.versionNumber == 3);
    size_t memberCount;
    bool way200;
    bool way201;
    bool node103;
    auto members = relation.members;
    while (!members.empty)
    {
        auto m = members.front;
        ++memberCount;
        if (m.type == ElementType.way && m.id == 200)
            way200 = true;
        if (m.type == ElementType.way && m.id == 201)
            way201 = true;
        if (m.type == ElementType.node && m.id == 103)
            node103 = true;
        members.popFront();
    }
    assert(memberCount == 3 && way200 && way201 && node103);

    // Final reverse-index snapshot.
    assert(parentWayCount(store, 100) == 0);
    assert(parentWayCount(store, 102) == 2);
    assert(parentWayCount(store, 103) == 2);
    assert(hasParentRelation(store, ElementType.way, 200, 300));
    assert(hasParentRelation(store, ElementType.way, 201, 300));
    assert(hasParentRelation(store, ElementType.node, 103, 300));

    const counts = store.counts;
    assert(counts.liveNodes == 3);
    assert(counts.liveWays == 2);
    assert(counts.liveRelations == 1);
}

private void assertNode(
    OsmStore store,
    OsmId id,
    int versionNumber,
    long latitude,
    string expectedName)
{
    StoreNodeView view;
    StoreStatus status;
    assert(store.node(id, view, status));
    assert(view.metadata.versionNumber == versionNumber);
    assert(view.location.latitudeNanodegrees == latitude);
    auto tags = view.tags;
    bool found;
    while (!tags.empty)
    {
        auto current = tags.front;
        if (current.key == cast(const(ubyte)[])"name")
        {
            assert(current.value == cast(const(ubyte)[])expectedName);
            found = true;
        }
        tags.popFront();
    }
    assert(found);
}

private void assertWayNodes(StoreWayView way, const(long)[] expected)
{
    auto nodes = way.nodes;
    size_t i;
    while (!nodes.empty)
    {
        assert(i < expected.length);
        assert(nodes.front.id == expected[i]);
        ++i;
        nodes.popFront();
    }
    assert(i == expected.length);
}

private bool hasElement(OsmStore store, ElementType type, OsmId id)
{
    OsmHandle handle;
    return store.find(type, id, handle);
}

private int nodeVersion(OsmStore store, OsmId id)
{
    StoreNodeView view;
    StoreStatus status;
    assert(store.node(id, view, status));
    return view.metadata.versionNumber;
}

private size_t parentWayCount(OsmStore store, OsmId nodeId)
{
    auto parents = store.parentWays(nodeId);
    size_t count;
    while (!parents.empty)
    {
        ++count;
        parents.popFront();
    }
    return count;
}

private bool hasParentWay(OsmStore store, OsmId nodeId, OsmId wayId)
{
    auto parents = store.parentWays(nodeId);
    while (!parents.empty)
    {
        if (parents.front.id == wayId)
            return true;
        parents.popFront();
    }
    return false;
}

private bool hasParentRelation(
    OsmStore store,
    ElementType type,
    OsmId id,
    OsmId relationId)
{
    auto parents = store.parentRelations(type, id);
    while (!parents.empty)
    {
        if (parents.front.id == relationId)
            return true;
        parents.popFront();
    }
    return false;
}

private ReplicationFeed makeFeed()
{
    ReplicationFeed result;
    assert(ReplicationFeed.create(
        "m19-authored-minute",
        ReplicationGranularity.minute,
        result));
    return result;
}

private ReplicationCheckpoint checkpoint(
    ReplicationFeed feed,
    ReplicationState state)
{
    ReplicationCheckpoint result;
    result.feed = feed;
    result.state = state;
    assert(result.valid);
    return result;
}

private ReplicationState state(
    ulong sequence,
    long unixSeconds,
    string isoUtc)
{
    ReplicationState result;
    result.sequenceNumber = sequence;
    result.timestamp =
        ReplicationTimestamp.fromUnixSeconds(unixSeconds);
    result.timestamp.isoUtc = isoUtc;
    assert(result.valid);
    return result;
}

private OwnedMetadata metadata(int versionNumber, bool visible)
{
    OwnedMetadata result;
    result.hasVersion = true;
    result.versionNumber = versionNumber;
    result.hasVisibility = true;
    result.visible = visible;
    return result;
}

private OwnedNode node(
    OsmId id,
    int versionNumber,
    long latitude,
    long longitude,
    string name)
{
    OwnedNode result;
    result.id = id;
    result.metadata = metadata(versionNumber, true);
    result.location = LocationView(latitude, longitude);
    result.tags ~= tag("name", name);
    return result;
}

private OwnedNodeRef nodeRef(OsmId id)
{
    OwnedNodeRef result;
    result.id = id;
    return result;
}

private OwnedTag tag(string key, string value)
{
    return OwnedTag(
        ownBytes(cast(const(ubyte)[])key),
        ownBytes(cast(const(ubyte)[])value));
}

private OwnedRelationMember member(
    ElementType type,
    OsmId id,
    string role)
{
    OwnedRelationMember result;
    result.type = type;
    result.id = id;
    result.role = ownBytes(cast(const(ubyte)[])role);
    return result;
}
