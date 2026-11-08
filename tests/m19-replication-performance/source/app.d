module app;

import compression.core : DecodeStatus;
import compression.encode :
    encodeGzipStored,
    gzipStoredSize;
import core.memory : GC;
import osm.model.owned :
    OwnedMetadata,
    OwnedNode,
    OwnedTag,
    ownBytes;
import osm.replication;
import osm.store;
import osm.view.element : ElementType;
import osm.view.location : LocationView;
import std.datetime.stopwatch : StopWatch;
import std.format : format;
import std.stdio : writefln;
import transport.source : MemorySource;

enum size_t sequenceCount = 256;
enum ulong firstSequence = 20_000;

@safe void main()
{
    auto feed = makeFeed();
    auto checkpoint = makeCheckpoint(
        feed,
        makeState(firstSequence, 1_762_620_000));

    auto store = new OsmStore();
    StoreStatus storeStatus;
    OsmHandle handle;

    OwnedNode initial;
    initial.id = 1000;
    initial.metadata = metadata(1);
    initial.location =
        LocationView(48_000_000_000L, 16_000_000_000L);
    initial.tags ~= tag("name", "v1");
    assert(store.add(initial, handle, storeStatus));

    ReplicationIngestOptions options;
    options.compressedBufferSize = 257;
    options.maximumCompressedBytes = 4096;
    options.maximumDecodedBytes = 4096;
    options.maximumExpansionRatio = 128;
    options.osmChange.bufferSize = 257;
    options.osmChange.maximumChildrenPerElement = 64;
    options.osmChange.maximumXmlDeclarationBytes = 256;

    const logicalBefore = store.memoryUsage.totalOwnedBytes;
    const gcBefore = GC.allocatedInCurrentThread();

    ulong applied;
    ulong replayed;
    ulong stale;
    ulong compressedBytes;
    ulong decodedBytes;

    StopWatch watch;
    watch.start();

    foreach (i; 0 .. sequenceCount)
    {
        const currentVersion = cast(int)i + 1;
        const nextVersion = currentVersion + 1;
        const sequence = firstSequence + i + 1;

        // Each resource contains one exact already-known version followed by
        // the next version. This records ordinary replay filtering while still
        // advancing every replication sequence.
        const xml = format(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            ~ "<osmChange version=\"0.6\" generator=\"osm-d-m19-workload\">"
            ~ "<modify>"
            ~ "<node id=\"1000\" version=\"%s\" visible=\"true\" "
            ~ "lat=\"48.0000000\" lon=\"16.0000000\">"
            ~ "<tag k=\"name\" v=\"v%s\"/></node>"
            ~ "<node id=\"1000\" version=\"%s\" visible=\"true\" "
            ~ "lat=\"48.0000000\" lon=\"16.0000000\">"
            ~ "<tag k=\"name\" v=\"v%s\"/></node>"
            ~ "</modify></osmChange>",
            currentVersion,
            currentVersion,
            nextVersion,
            nextVersion);

        auto encoded = gzip(xml);
        auto source = new MemorySource(encoded);
        auto state = makeState(
            sequence,
            1_762_620_000 + cast(long)i + 1);

        ReplicationApplyResult result;
        ReplicationIngestStatus status;
        if (!applyGzipReplicationStep(
                store,
                source,
                checkpoint,
                feed,
                state,
                result,
                status,
                options))
        {
            throw new Exception(format(
                "M19 workload failed at sequence %s: stage=%s compression=%s xml=%s apply=%s",
                sequence,
                status.error,
                status.compressionError.code,
                status.osmChangeStatus.error,
                status.applyStatus.error));
        }

        checkpoint = result.checkpoint;
        applied += result.stagedTransitions;
        replayed += result.replayedEntries;
        stale += result.staleEntries;
        compressedBytes += status.compressedBytesRead;
        decodedBytes += status.decodedBytes;
    }

    watch.stop();

    const gcAfter = GC.allocatedInCurrentThread();
    const logicalAfter = store.memoryUsage.totalOwnedBytes;
    const elapsedUsecs = watch.peek.total!"usecs";

    assert(checkpoint.state.sequenceNumber ==
        firstSequence + sequenceCount);
    assert(applied == sequenceCount);
    assert(replayed == sequenceCount);
    assert(stale == 0);

    StoreNodeView finalNode;
    assert(store.node(1000, finalNode, storeStatus));
    assert(finalNode.metadata.versionNumber ==
        cast(int)sequenceCount + 1);

    const counts = store.counts;
    assert(counts.liveNodes == 1);
    assert(counts.liveWays == 0);
    assert(counts.liveRelations == 0);

    // Replacing one identity repeatedly may grow append-only pools, but memory
    // growth is bounded by the finite workload and remains observable.
    assert(logicalAfter < 2 * 1024 * 1024);

    const seconds = cast(double)elapsedUsecs / 1_000_000.0;
    const perSecond = seconds == 0
        ? 0.0
        : cast(double)sequenceCount / seconds;

    writefln(
        "M19_REPLICATION_WORKLOAD sequences=%s applied=%s replayed=%s stale=%s final_sequence=%s compressed_bytes=%s decoded_bytes=%s elapsed_us=%s sequences_per_second=%.2f gc_allocated_bytes=%s logical_store_before=%s logical_store_after=%s",
        sequenceCount,
        applied,
        replayed,
        stale,
        checkpoint.state.sequenceNumber,
        compressedBytes,
        decodedBytes,
        elapsedUsecs,
        perSecond,
        gcAfter - gcBefore,
        logicalBefore,
        logicalAfter);
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

private ReplicationFeed makeFeed() @safe
{
    ReplicationFeed feed;
    assert(ReplicationFeed.create(
        "m19-workload",
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

private ReplicationState makeState(
    ulong sequence,
    long unixSeconds) @safe pure nothrow @nogc
{
    ReplicationState result;
    result.sequenceNumber = sequence;
    result.timestamp =
        ReplicationTimestamp.fromUnixSeconds(unixSeconds);
    return result;
}

private OwnedMetadata metadata(int version) @safe pure nothrow
{
    OwnedMetadata result;
    result.hasVersion = true;
    result.versionNumber = version;
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
