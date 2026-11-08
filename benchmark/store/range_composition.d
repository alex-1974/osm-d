/**
 * M14 OsmStore range-composition qualification.
 *
 * This benchmark isolates traversal abstraction cost after a complete compact
 * store has already been built. PBF I/O, parsing and store construction are
 * deliberately outside the timed region.
 */
module osm.benchmark.store.range_composition;

import core.memory : GC;

import osm :
    OsmStore,
    PbfReadSummary,
    PbfStoreReadStatus,
    StoreElementState,
    hasTag,
    readPbfStore;

import std.algorithm.iteration : cache, filter;
import std.algorithm.sorting : sort;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : stderr, writefln;

private enum sampleCount = 21;

private struct TraversalResult
{
    ulong checksum;
    size_t matches;
}

private struct Timing
{
    long p10;
    long p50;
    long p90;
    size_t gcAllocatedBytes;
    size_t gcCollections;
    TraversalResult result;
}

private struct CompositionTiming
{
    Timing direct;
    Timing plain;
    Timing cached;
}

private void mix(ref ulong hash, long id) @safe pure nothrow @nogc
{
    hash ^= cast(ulong)id + 0x9e3779b97f4a7c15UL +
        (hash << 6) + (hash >> 2);
}

private TraversalResult directState(OsmStore store)
    @safe nothrow @nogc
{
    TraversalResult result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = store.ways;
    while (!ways.empty)
    {
        auto way = ways.front;
        if (way.state == StoreElementState.clean)
        {
            ++result.matches;
            mix(result.checksum, way.id);
        }
        ways.popFront();
    }
    return result;
}

private TraversalResult composedState(OsmStore store)
    @safe nothrow @nogc
{
    TraversalResult result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = store.ways
        .filter!(way => way.state == StoreElementState.clean);
    while (!ways.empty)
    {
        const way = ways.front;
        ++result.matches;
        mix(result.checksum, way.id);
        ways.popFront();
    }
    return result;
}

private TraversalResult directId(OsmStore store)
    @safe nothrow @nogc
{
    TraversalResult result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = store.ways;
    while (!ways.empty)
    {
        auto way = ways.front;
        if ((way.id & 1) == 0)
        {
            ++result.matches;
            mix(result.checksum, way.id);
        }
        ways.popFront();
    }
    return result;
}

private TraversalResult composedId(OsmStore store)
    @safe nothrow @nogc
{
    TraversalResult result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = store.ways.filter!(way => (way.id & 1) == 0);
    while (!ways.empty)
    {
        const way = ways.front;
        ++result.matches;
        mix(result.checksum, way.id);
        ways.popFront();
    }
    return result;
}

private TraversalResult directTag(OsmStore store)
    @safe nothrow @nogc
{
    TraversalResult result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = store.ways;
    while (!ways.empty)
    {
        auto way = ways.front;
        if (way.tags.hasTag("highway"))
        {
            ++result.matches;
            mix(result.checksum, way.id);
        }
        ways.popFront();
    }
    return result;
}

private TraversalResult composedTag(OsmStore store)
    @safe nothrow @nogc
{
    TraversalResult result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = store.ways
        .filter!(way => way.tags.hasTag("highway"));
    while (!ways.empty)
    {
        const way = ways.front;
        ++result.matches;
        mix(result.checksum, way.id);
        ways.popFront();
    }
    return result;
}

private TraversalResult directChained(OsmStore store)
    @safe nothrow @nogc
{
    TraversalResult result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = store.ways;
    while (!ways.empty)
    {
        auto way = ways.front;
        if ((way.id & 1) == 0 && way.tags.hasTag("highway"))
        {
            ++result.matches;
            mix(result.checksum, way.id);
        }
        ways.popFront();
    }
    return result;
}

private TraversalResult composedChained(OsmStore store)
    @safe nothrow @nogc
{
    TraversalResult result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = store.ways
        .filter!(way => (way.id & 1) == 0)
        .filter!(way => way.tags.hasTag("highway"));
    while (!ways.empty)
    {
        const way = ways.front;
        ++result.matches;
        mix(result.checksum, way.id);
        ways.popFront();
    }
    return result;
}

private TraversalResult cachedState(OsmStore store)
    @safe nothrow @nogc
{
    TraversalResult result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = store.ways
        .cache
        .filter!(way => way.state == StoreElementState.clean);
    while (!ways.empty)
    {
        const way = ways.front;
        ++result.matches;
        mix(result.checksum, way.id);
        ways.popFront();
    }
    return result;
}

private TraversalResult cachedId(OsmStore store)
    @safe nothrow @nogc
{
    TraversalResult result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = store.ways
        .cache
        .filter!(way => (way.id & 1) == 0);
    while (!ways.empty)
    {
        const way = ways.front;
        ++result.matches;
        mix(result.checksum, way.id);
        ways.popFront();
    }
    return result;
}

private TraversalResult cachedTag(OsmStore store)
    @safe nothrow @nogc
{
    TraversalResult result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = store.ways
        .cache
        .filter!(way => way.tags.hasTag("highway"));
    while (!ways.empty)
    {
        const way = ways.front;
        ++result.matches;
        mix(result.checksum, way.id);
        ways.popFront();
    }
    return result;
}

private TraversalResult cachedChained(OsmStore store)
    @safe nothrow @nogc
{
    TraversalResult result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = store.ways
        .cache
        .filter!(way => (way.id & 1) == 0)
        .filter!(way => way.tags.hasTag("highway"));
    while (!ways.empty)
    {
        const way = ways.front;
        ++result.matches;
        mix(result.checksum, way.id);
        ways.popFront();
    }
    return result;
}

private long elapsedNs(alias traversal)(
    OsmStore store,
    out TraversalResult result)
    @trusted
{
    StopWatch sw = StopWatch(AutoStart.yes);
    result = traversal(store);
    sw.stop();

    // Keep the result observable at the call boundary. Semantic parity is
    // checked by the caller outside the timed interval.
    if (result.checksum == ulong.max && result.matches == size_t.max)
        stderr.writeln("unreachable benchmark sentinel");

    return sw.peek.total!"nsecs";
}

private ulong allocatedInCurrentThread() @trusted nothrow
{
    return GC.allocatedInCurrentThread();
}

private Timing summarize(
    ref long[sampleCount] values,
    TraversalResult result,
    size_t allocated,
    size_t collections)
    @safe
{
    sort(values[]);
    Timing timing;
    timing.p10 = values[(sampleCount * 10) / 100];
    timing.p50 = values[sampleCount / 2];
    timing.p90 = values[(sampleCount * 90) / 100];
    timing.gcAllocatedBytes = allocated;
    timing.gcCollections = collections;
    timing.result = result;
    return timing;
}

private Timing allocationTiming(alias traversal)(OsmStore store)
    @safe
{
    GC.collect();
    const allocatedBefore = allocatedInCurrentThread();
    const profileBefore = GC.profileStats();
    const result = traversal(store);
    const profileAfter = GC.profileStats();
    const allocatedAfter = allocatedInCurrentThread();

    Timing timing;
    timing.gcAllocatedBytes = allocatedAfter - allocatedBefore;
    timing.gcCollections =
        profileAfter.numCollections - profileBefore.numCollections;
    timing.result = result;
    return timing;
}

private CompositionTiming measureComposition(
    alias directTraversal,
    alias plainTraversal,
    alias cachedTraversal)(
    OsmStore store)
    @safe
{
    foreach (_; 0 .. 3)
    {
        const direct = directTraversal(store);
        const plain = plainTraversal(store);
        const cached = cachedTraversal(store);
        assert(direct == plain);
        assert(direct == cached);
    }

    Timing directAllocation = allocationTiming!directTraversal(store);
    Timing plainAllocation = allocationTiming!plainTraversal(store);
    Timing cachedAllocation = allocationTiming!cachedTraversal(store);
    assert(directAllocation.result == plainAllocation.result);
    assert(directAllocation.result == cachedAllocation.result);

    long[sampleCount] directSamples;
    long[sampleCount] plainSamples;
    long[sampleCount] cachedSamples;
    TraversalResult expected;

    foreach (sample; 0 .. sampleCount)
    {
        TraversalResult directResult;
        TraversalResult plainResult;
        TraversalResult cachedResult;

        final switch (sample % 3)
        {
        case 0:
            directSamples[sample] =
                elapsedNs!directTraversal(store, directResult);
            plainSamples[sample] =
                elapsedNs!plainTraversal(store, plainResult);
            cachedSamples[sample] =
                elapsedNs!cachedTraversal(store, cachedResult);
            break;
        case 1:
            plainSamples[sample] =
                elapsedNs!plainTraversal(store, plainResult);
            cachedSamples[sample] =
                elapsedNs!cachedTraversal(store, cachedResult);
            directSamples[sample] =
                elapsedNs!directTraversal(store, directResult);
            break;
        case 2:
            cachedSamples[sample] =
                elapsedNs!cachedTraversal(store, cachedResult);
            directSamples[sample] =
                elapsedNs!directTraversal(store, directResult);
            plainSamples[sample] =
                elapsedNs!plainTraversal(store, plainResult);
            break;
        }

        assert(directResult == plainResult);
        assert(directResult == cachedResult);
        if (sample == 0)
            expected = directResult;
        else
            assert(directResult == expected);
    }

    CompositionTiming result;
    result.direct = summarize(
        directSamples,
        expected,
        directAllocation.gcAllocatedBytes,
        directAllocation.gcCollections);
    result.plain = summarize(
        plainSamples,
        expected,
        plainAllocation.gcAllocatedBytes,
        plainAllocation.gcCollections);
    result.cached = summarize(
        cachedSamples,
        expected,
        cachedAllocation.gcAllocatedBytes,
        cachedAllocation.gcCollections);
    return result;
}

private void printComposition(string name, CompositionTiming timing)
{
    writefln("%s_matches=%s", name, timing.direct.result.matches);
    writefln("%s_checksum=%s", name, timing.direct.result.checksum);

    writefln("%s_direct_p10_ns=%s", name, timing.direct.p10);
    writefln("%s_direct_p50_ns=%s", name, timing.direct.p50);
    writefln("%s_direct_p90_ns=%s", name, timing.direct.p90);

    writefln("%s_plain_p10_ns=%s", name, timing.plain.p10);
    writefln("%s_plain_p50_ns=%s", name, timing.plain.p50);
    writefln("%s_plain_p90_ns=%s", name, timing.plain.p90);
    writefln(
        "%s_plain_over_direct=%.6f",
        name,
        timing.direct.p50 == 0
            ? 0.0
            : cast(double)timing.plain.p50 /
                cast(double)timing.direct.p50);

    writefln("%s_cached_p10_ns=%s", name, timing.cached.p10);
    writefln("%s_cached_p50_ns=%s", name, timing.cached.p50);
    writefln("%s_cached_p90_ns=%s", name, timing.cached.p90);
    writefln(
        "%s_cached_over_direct=%.6f",
        name,
        timing.direct.p50 == 0
            ? 0.0
            : cast(double)timing.cached.p50 /
                cast(double)timing.direct.p50);

    writefln(
        "%s_direct_gc_allocated_bytes=%s",
        name,
        timing.direct.gcAllocatedBytes);
    writefln(
        "%s_plain_gc_allocated_bytes=%s",
        name,
        timing.plain.gcAllocatedBytes);
    writefln(
        "%s_cached_gc_allocated_bytes=%s",
        name,
        timing.cached.gcAllocatedBytes);
    writefln(
        "%s_direct_gc_collections=%s",
        name,
        timing.direct.gcCollections);
    writefln(
        "%s_plain_gc_collections=%s",
        name,
        timing.plain.gcCollections);
    writefln(
        "%s_cached_gc_collections=%s",
        name,
        timing.cached.gcCollections);
}

int main(string[] args)
{
    if (args.length != 2)
    {
        stderr.writefln("usage: %s FILE.osm.pbf", args[0]);
        return 2;
    }

    auto storage = cast(ubyte[])read(args[1]);
    const input = cast(const(ubyte)[])storage;

    OsmStore store;
    PbfReadSummary summary;
    PbfStoreReadStatus status;
    if (!readPbfStore(input, store, summary, status))
    {
        stderr.writefln(
            "PBF store read failed: pbf_error=%s store_error=%s",
            status.pbf.error,
            status.store.error);
        return 1;
    }

    writefln("input_bytes=%s", storage.length);
    writefln("nodes=%s", summary.nodes);
    writefln("ways=%s", summary.ways);
    writefln("relations=%s", summary.relations);
    writefln("samples=%s", sampleCount);

    printComposition(
        "state",
        measureComposition!(directState, composedState, cachedState)(store));
    printComposition(
        "id",
        measureComposition!(directId, composedId, cachedId)(store));
    printComposition(
        "tag",
        measureComposition!(directTag, composedTag, cachedTag)(store));
    printComposition(
        "chained",
        measureComposition!(
            directChained,
            composedChained,
            cachedChained)(store));

    return 0;
}
