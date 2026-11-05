/**
 * M14 ByteSource PBF qualification benchmark.
 *
 * Each process runs exactly one mode so /usr/bin/time can record a meaningful
 * per-mode peak RSS. Whole-buffer and MemorySource modes load the input before
 * the timed passes; FileSource modes leave resource access inside the measured
 * operation.
 */
module osm.benchmark.parser.source_compare;

import core.memory : GC;

import osm :
    NodeView,
    OsmStore,
    PbfReadStatus,
    PbfReadSummary,
    PbfReader,
    PbfReaderWorkspace,
    PbfSourceReadStatus,
    PbfSourceStoreReadStatus,
    PbfStoreReadStatus,
    RelationView,
    StoreCounts,
    WayView,
    readPbfStore;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : stderr, writefln;

import transport :
    ByteRange,
    ByteSource,
    FileSource,
    MemorySource,
    ReadError,
    ReadLimits,
    ReadResult,
    SourceInfo;

private enum ulong hashSeed = 0x243f6a8885a308d3UL;

private final class TrackingSource : ByteSource
{
private:
    ByteSource inner;
    ubyte phase;

public:
    ulong readSomeCalls;
    ulong totalBytesRead;
    size_t maxHeaderBytes;
    size_t maxBlobBytes;

    this(ByteSource inner) @safe
    {
        this.inner = inner;
    }

    @property SourceInfo sourceInfo() const @safe
    {
        return inner.sourceInfo;
    }

    ReadResult read(
        ByteRange range,
        scope ubyte[] destination,
        ReadLimits limits = ReadLimits.init) @safe
    {
        return inner.read(range, destination, limits);
    }

    ReadResult readSome(
        ulong offset,
        scope ubyte[] destination,
        ReadLimits limits = ReadLimits.init) @safe
    {
        ++readSomeCalls;
        auto result = inner.readSome(offset, destination, limits);
        totalBytesRead += result.bytesRead;

        if (result.ok)
        {
            final switch (phase)
            {
            case 0:
                assert(destination.length == 4);
                phase = 1;
                break;
            case 1:
                if (destination.length > maxHeaderBytes)
                    maxHeaderBytes = destination.length;
                phase = 2;
                break;
            case 2:
                if (destination.length > maxBlobBytes)
                    maxBlobBytes = destination.length;
                phase = 0;
                break;
            }
        }

        return result;
    }

    @property size_t retainedEncodedBufferBytes() const
        @safe pure nothrow @nogc
    {
        return maxHeaderBytes + maxBlobBytes;
    }
}

private void printSourceMetrics(TrackingSource source)
{
    writefln("source_read_some_calls=%s", source.readSomeCalls);
    writefln("source_bytes_read=%s", source.totalBytesRead);
    writefln("source_max_header_bytes=%s", source.maxHeaderBytes);
    writefln("source_max_blob_bytes=%s", source.maxBlobBytes);
    writefln(
        "source_retained_encoded_buffer_bytes=%s",
        source.retainedEncodedBufferBytes);
}

private struct SemanticHandler
{
    ulong checksum = hashSeed;

    void node(scope ref NodeView value) @safe nothrow @nogc
    {
        mix(checksum, value.id, 1);
    }

    void way(scope ref WayView value) @safe nothrow @nogc
    {
        mix(checksum, value.id, 2);
    }

    void relation(scope ref RelationView value) @safe nothrow @nogc
    {
        mix(checksum, value.id, 3);
    }
}

private void mix(ref ulong hash, long id, ulong kind)
    @safe pure nothrow @nogc
{
    hash ^= (cast(ulong)id * 0x9e3779b97f4a7c15UL) ^
        (kind * 0xbf58476d1ce4e5b9UL);
    hash = (hash << 13) | (hash >> (64 - 13));
    hash *= 0x94d049bb133111ebUL;
}

private ulong allocatedInCurrentThread() @trusted nothrow
{
    return GC.allocatedInCurrentThread();
}

private long elapsedNs(scope void delegate() operation) @trusted
{
    StopWatch sw = StopWatch(AutoStart.yes);
    operation();
    sw.stop();
    return sw.peek.total!"nsecs";
}

private void printSummary(
    scope const PbfReadSummary summary,
    ulong checksum)
{
    writefln(
        "semantic nodes=%s ways=%s relations=%s tags=%s groups=%s blocks=%s checksum=%s",
        summary.nodes,
        summary.ways,
        summary.relations,
        summary.tags,
        summary.primitiveGroups,
        summary.dataBlocks,
        checksum);
}

private void printStore(
    scope const PbfReadSummary summary,
    StoreCounts counts)
{
    writefln(
        "store nodes=%s ways=%s relations=%s summary_nodes=%s summary_ways=%s summary_relations=%s",
        counts.liveNodes,
        counts.liveWays,
        counts.liveRelations,
        summary.nodes,
        summary.ways,
        summary.relations);
}

private void printTimings(long[] values)
{
    sort(values);
    writefln("p10_ns=%s", values[(values.length * 10) / 100]);
    writefln("p50_ns=%s", values[values.length / 2]);
    writefln("p90_ns=%s", values[(values.length * 90) / 100]);
}

private int runSliceDecode(string filename, size_t passes)
{
    auto storage = cast(ubyte[])read(filename);
    const input = cast(const(ubyte)[])storage;

    PbfReader reader;
    PbfReaderWorkspace workspace;
    long[] timings = new long[passes];
    PbfReadSummary reference;
    ulong referenceChecksum;

    foreach (pass; 0 .. passes)
    {
        SemanticHandler handler;
        PbfReadSummary summary;
        PbfReadStatus status;

        const allocatedBefore = allocatedInCurrentThread();
        const collectionsBefore = GC.profileStats().numCollections;
        bool ok;
        timings[pass] = elapsedNs({
            ok = reader.read(input, workspace, handler, summary, status);
        });
        const allocatedAfter = allocatedInCurrentThread();
        const collectionsAfter = GC.profileStats().numCollections;

        if (!ok)
        {
            stderr.writefln(
                "slice decode failed: error=%s block=%s offset=%s",
                status.error,
                status.blockSequence,
                status.blockOffset);
            return 1;
        }

        if (pass == 0)
        {
            reference = summary;
            referenceChecksum = handler.checksum;
        }
        else if (summary != reference || handler.checksum != referenceChecksum)
        {
            stderr.writeln("slice semantic result changed between passes");
            return 1;
        }

        writefln(
            "pass=%s elapsed_ns=%s gc_allocated_bytes=%s gc_collections=%s warmup=%s",
            pass + 1,
            timings[pass],
            allocatedAfter - allocatedBefore,
            collectionsAfter - collectionsBefore,
            pass == 0 ? 1 : 0);
    }

    printSummary(reference, referenceChecksum);
    printTimings(timings[1 .. $]);
    writefln("input_bytes=%s", input.length);
    return 0;
}

private int runSourceDecode(
    string filename,
    size_t passes,
    bool memoryBacked)
{
    ubyte[] storage;
    ByteSource source;

    if (memoryBacked)
    {
        storage = cast(ubyte[])read(filename);
        source = new MemorySource(storage);
    }
    else
    {
        source = new FileSource(filename);
    }

    auto tracked = new TrackingSource(source);

    PbfReader reader;
    PbfReaderWorkspace workspace;
    long[] timings = new long[passes];
    PbfReadSummary reference;
    ulong referenceChecksum;

    foreach (pass; 0 .. passes)
    {
        SemanticHandler handler;
        PbfReadSummary summary;
        PbfSourceReadStatus status;

        const allocatedBefore = allocatedInCurrentThread();
        const collectionsBefore = GC.profileStats().numCollections;
        bool ok;
        timings[pass] = elapsedNs({
            ok = reader.read(tracked, workspace, handler, summary, status);
        });
        const allocatedAfter = allocatedInCurrentThread();
        const collectionsAfter = GC.profileStats().numCollections;

        if (!ok)
        {
            stderr.writefln(
                "source decode failed: transport=%s source_offset=%s pbf=%s block=%s",
                status.transportError,
                status.transportOffset,
                status.pbf.error,
                status.pbf.blockSequence);
            return 1;
        }

        if (pass == 0)
        {
            reference = summary;
            referenceChecksum = handler.checksum;
        }
        else if (summary != reference || handler.checksum != referenceChecksum)
        {
            stderr.writeln("source semantic result changed between passes");
            return 1;
        }

        writefln(
            "pass=%s elapsed_ns=%s gc_allocated_bytes=%s gc_collections=%s warmup=%s",
            pass + 1,
            timings[pass],
            allocatedAfter - allocatedBefore,
            collectionsAfter - collectionsBefore,
            pass == 0 ? 1 : 0);
    }

    printSummary(reference, referenceChecksum);
    printTimings(timings[1 .. $]);
    printSourceMetrics(tracked);
    writefln(
        "input_bytes=%s",
        memoryBacked ? storage.length : source.sourceInfo.length);
    return 0;
}

private int runFileRangeRead(string filename, size_t passes)
{
    auto source = new FileSource(filename);
    const info = source.sourceInfo;
    if (!info.lengthKnown || info.length > size_t.max)
    {
        stderr.writeln("FileSource did not provide a usable resource length");
        return 1;
    }

    auto buffer = new ubyte[cast(size_t)info.length];
    long[] timings = new long[passes];

    foreach (pass; 0 .. passes)
    {
        const allocatedBefore = allocatedInCurrentThread();
        const collectionsBefore = GC.profileStats().numCollections;
        auto result = typeof(source.read(
            ByteRange.init, buffer, ReadLimits.init)).init;

        timings[pass] = elapsedNs({
            result = source.read(
                ByteRange(0, buffer.length),
                buffer,
                ReadLimits(buffer.length));
        });

        const allocatedAfter = allocatedInCurrentThread();
        const collectionsAfter = GC.profileStats().numCollections;

        if (!result.ok || result.bytesRead != buffer.length)
        {
            stderr.writefln(
                "FileSource full range read failed: error=%s bytes=%s",
                result.error,
                result.bytesRead);
            return 1;
        }

        writefln(
            "pass=%s elapsed_ns=%s gc_allocated_bytes=%s gc_collections=%s warmup=%s",
            pass + 1,
            timings[pass],
            allocatedAfter - allocatedBefore,
            collectionsAfter - collectionsBefore,
            pass == 0 ? 1 : 0);
    }

    printTimings(timings[1 .. $]);
    writefln("input_bytes=%s", buffer.length);
    return 0;
}

private int runStore(
    string filename,
    size_t passes,
    bool sourceBacked,
    bool memoryBacked)
{
    ubyte[] storage;
    if (!sourceBacked || memoryBacked)
        storage = cast(ubyte[])read(filename);

    TrackingSource tracked;
    if (sourceBacked)
    {
        ByteSource source = memoryBacked
            ? cast(ByteSource)new MemorySource(storage)
            : cast(ByteSource)new FileSource(filename);
        tracked = new TrackingSource(source);
    }

    long[] timings = new long[passes];
    PbfReadSummary referenceSummary;
    StoreCounts referenceCounts;

    foreach (pass; 0 .. passes)
    {
        // A store is durable by design. Release the previous pass and collect
        // outside the timed interval so timings measure one complete build.
        GC.collect();

        OsmStore store;
        PbfReadSummary summary;
        bool ok;

        const allocatedBefore = allocatedInCurrentThread();
        const collectionsBefore = GC.profileStats().numCollections;

        if (!sourceBacked)
        {
            PbfStoreReadStatus status;
            timings[pass] = elapsedNs({
                ok = readPbfStore(storage, store, summary, status);
            });
            if (!ok)
            {
                stderr.writefln(
                    "slice store build failed: pbf=%s store=%s",
                    status.pbf.error,
                    status.store.error);
                return 1;
            }
        }
        else
        {
            PbfSourceStoreReadStatus status;
            timings[pass] = elapsedNs({
                ok = readPbfStore(tracked, store, summary, status);
            });
            if (!ok)
            {
                stderr.writefln(
                    "source store build failed: transport=%s pbf=%s store=%s",
                    status.source.transportError,
                    status.source.pbf.error,
                    status.store.error);
                return 1;
            }
        }

        const allocatedAfter = allocatedInCurrentThread();
        const collectionsAfter = GC.profileStats().numCollections;
        const counts = store.counts;

        if (pass == 0)
        {
            referenceSummary = summary;
            referenceCounts = counts;
        }
        else if (summary != referenceSummary || counts != referenceCounts)
        {
            stderr.writeln("store result changed between passes");
            return 1;
        }

        writefln(
            "pass=%s elapsed_ns=%s gc_allocated_bytes=%s gc_collections=%s warmup=%s",
            pass + 1,
            timings[pass],
            allocatedAfter - allocatedBefore,
            collectionsAfter - collectionsBefore,
            pass == 0 ? 1 : 0);

        store = null;
    }

    printStore(referenceSummary, referenceCounts);
    printTimings(timings[1 .. $]);
    if (sourceBacked)
        printSourceMetrics(tracked);
    if (storage.length != 0)
        writefln("input_bytes=%s", storage.length);
    else if (sourceBacked)
        writefln("input_bytes=%s", tracked.sourceInfo.length);
    return 0;
}

int main(string[] args)
{
    if (args.length != 4)
    {
        stderr.writefln(
            "usage: %s MODE PASSES FILE.osm.pbf",
            args[0]);
        return 2;
    }

    const mode = args[1];
    const passes = to!size_t(args[2]);
    const filename = args[3];

    if (passes < 3)
    {
        stderr.writeln("PASSES must be at least 3 (warm-up + timed samples)");
        return 2;
    }

    writefln("mode=%s", mode);
    writefln("passes=%s", passes);

    switch (mode)
    {
    case "slice-decode":
        return runSliceDecode(filename, passes);
    case "memory-source-decode":
        return runSourceDecode(filename, passes, true);
    case "file-source-decode":
        return runSourceDecode(filename, passes, false);
    case "file-range-read":
        return runFileRangeRead(filename, passes);
    case "slice-store":
        return runStore(filename, passes, false, false);
    case "memory-source-store":
        return runStore(filename, passes, true, true);
    case "file-source-store":
        return runStore(filename, passes, true, false);
    default:
        stderr.writefln("unknown mode: %s", mode);
        return 2;
    }
}
