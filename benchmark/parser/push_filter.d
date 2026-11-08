/**
 * M14 benchmark-local prototype for composable PBF push filtering.
 *
 * The candidate deliberately wraps the existing opApply/foreach traversal; it
 * is not a Phobos InputRange and does not materialize Ways.
 */
module osm.benchmark.parser.push_filter;

import core.memory : GC;

import osm :
    PbfReadStatus,
    PbfReadSummary,
    PbfReader,
    PbfReaderWorkspace,
    PbfWayIterable,
    WayView,
    hasTag,
    pbfWays;

import std.algorithm.sorting : sort;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : stderr, writefln;

private enum sampleCount = 21;

private struct Result
{
    size_t matches;
    ulong checksum;
}

private struct Timing
{
    long p10;
    long p50;
    long p90;
    ulong gcAllocatedBytes;
    size_t gcCollections;
    Result result;
}

private struct Comparison
{
    Timing direct;
    Timing inlineFilter;
    Timing pushFilter;
}

private void mix(ref ulong hash, long id) @safe pure nothrow @nogc
{
    hash ^= cast(ulong)id + 0x9e3779b97f4a7c15UL +
        (hash << 6) + (hash >> 2);
}

private struct DirectHandler(alias predicate)
{
    Result result;

    void way(scope ref WayView way) @safe nothrow @nogc
    {
        if (!predicate(way))
            return;

        ++result.matches;
        mix(result.checksum, way.id);
    }
}

private Result runDirect(alias predicate)(const(ubyte)[] input)
    @safe
{
    DirectHandler!predicate handler;
    handler.result.checksum = 0x243f6a8885a308d3UL;

    PbfReader reader;
    PbfReaderWorkspace workspace;
    PbfReadSummary summary;
    PbfReadStatus status;
    if (!reader.read(input, workspace, handler, summary, status))
        assert(0, "direct PBF traversal failed");

    return handler.result;
}

private Result runInline(alias predicate)(const(ubyte)[] input)
    @safe
{
    Result result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = pbfWays(input);
    foreach (scope ref WayView way; ways)
    {
        if (!predicate(way))
            continue;

        ++result.matches;
        mix(result.checksum, way.id);
    }

    assert(ways.completed);
    assert(ways.status.ok);
    return result;
}

private struct BenchmarkWhereWays(alias predicate)
{
private:
    PbfWayIterable source;

public:
    this(PbfWayIterable value) @safe pure nothrow @nogc
    {
        source = value;
    }

    @property PbfReadStatus status() const @safe pure nothrow @nogc
    {
        return source.status;
    }

    @property bool completed() const @safe pure nothrow @nogc
    {
        return source.completed;
    }

    int opApply(
        scope int delegate(scope ref WayView) @safe dg)
        @safe
    {
        return source.opApply((scope ref WayView way) @safe {
            if (!predicate(way))
                return 0;
            return dg(way);
        });
    }
}

private BenchmarkWhereWays!predicate whereWays(alias predicate)(
    PbfWayIterable source)
    @safe pure nothrow @nogc
{
    return BenchmarkWhereWays!predicate(source);
}

private Result runPush(alias predicate)(const(ubyte)[] input)
    @safe
{
    Result result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto ways = whereWays!predicate(pbfWays(input));
    foreach (scope ref WayView way; ways)
    {
        ++result.matches;
        mix(result.checksum, way.id);
    }

    assert(ways.completed);
    assert(ways.status.ok);
    return result;
}

private bool highSelectivity(scope ref WayView way)
    @safe pure nothrow @nogc
{
    return (way.id & 7) != 0;
}

private bool lowSelectivity(scope ref WayView way)
    @safe pure nothrow @nogc
{
    return (way.id & 1023) == 0;
}

private bool highway(scope ref WayView way)
    @safe nothrow @nogc
{
    return way.tags.hasTag("highway");
}

private ulong allocatedInCurrentThread() @trusted nothrow
{
    return GC.allocatedInCurrentThread();
}

private long elapsedNs(alias operation)(
    const(ubyte)[] input,
    out Result result)
    @trusted
{
    StopWatch sw = StopWatch(AutoStart.yes);
    result = operation(input);
    sw.stop();
    return sw.peek.total!"nsecs";
}

private Timing allocationTiming(alias operation)(const(ubyte)[] input)
    @safe
{
    GC.collect();
    const allocatedBefore = allocatedInCurrentThread();
    const profileBefore = GC.profileStats();
    const result = operation(input);
    const profileAfter = GC.profileStats();
    const allocatedAfter = allocatedInCurrentThread();

    Timing timing;
    timing.gcAllocatedBytes = allocatedAfter - allocatedBefore;
    timing.gcCollections =
        profileAfter.numCollections - profileBefore.numCollections;
    timing.result = result;
    return timing;
}

private Timing summarize(
    ref long[sampleCount] samples,
    Result result,
    ulong allocated,
    size_t collections)
    @safe
{
    sort(samples[]);
    Timing timing;
    timing.p10 = samples[(sampleCount * 10) / 100];
    timing.p50 = samples[sampleCount / 2];
    timing.p90 = samples[(sampleCount * 90) / 100];
    timing.gcAllocatedBytes = allocated;
    timing.gcCollections = collections;
    timing.result = result;
    return timing;
}

private Comparison measure(alias predicate)(const(ubyte)[] input)
    @safe
{
    foreach (_; 0 .. 2)
    {
        const direct = runDirect!predicate(input);
        const inlineFilter = runInline!predicate(input);
        const pushFilter = runPush!predicate(input);
        assert(direct == inlineFilter);
        assert(direct == pushFilter);
    }

    const directAllocation = allocationTiming!(runDirect!predicate)(input);
    const inlineAllocation = allocationTiming!(runInline!predicate)(input);
    const pushAllocation = allocationTiming!(runPush!predicate)(input);

    assert(directAllocation.result == inlineAllocation.result);
    assert(directAllocation.result == pushAllocation.result);

    long[sampleCount] directSamples;
    long[sampleCount] inlineSamples;
    long[sampleCount] pushSamples;
    Result expected;

    foreach (sample; 0 .. sampleCount)
    {
        Result direct;
        Result inlineFilter;
        Result pushFilter;

        final switch (sample % 3)
        {
        case 0:
            directSamples[sample] =
                elapsedNs!(runDirect!predicate)(input, direct);
            inlineSamples[sample] =
                elapsedNs!(runInline!predicate)(input, inlineFilter);
            pushSamples[sample] =
                elapsedNs!(runPush!predicate)(input, pushFilter);
            break;
        case 1:
            inlineSamples[sample] =
                elapsedNs!(runInline!predicate)(input, inlineFilter);
            pushSamples[sample] =
                elapsedNs!(runPush!predicate)(input, pushFilter);
            directSamples[sample] =
                elapsedNs!(runDirect!predicate)(input, direct);
            break;
        case 2:
            pushSamples[sample] =
                elapsedNs!(runPush!predicate)(input, pushFilter);
            directSamples[sample] =
                elapsedNs!(runDirect!predicate)(input, direct);
            inlineSamples[sample] =
                elapsedNs!(runInline!predicate)(input, inlineFilter);
            break;
        }

        assert(direct == inlineFilter);
        assert(direct == pushFilter);

        if (sample == 0)
            expected = direct;
        else
            assert(direct == expected);
    }

    Comparison result;
    result.direct = summarize(
        directSamples,
        expected,
        directAllocation.gcAllocatedBytes,
        directAllocation.gcCollections);
    result.inlineFilter = summarize(
        inlineSamples,
        expected,
        inlineAllocation.gcAllocatedBytes,
        inlineAllocation.gcCollections);
    result.pushFilter = summarize(
        pushSamples,
        expected,
        pushAllocation.gcAllocatedBytes,
        pushAllocation.gcCollections);
    return result;
}

private void printTiming(string name, Comparison value)
{
    writefln("%s_matches=%s", name, value.direct.result.matches);
    writefln("%s_checksum=%s", name, value.direct.result.checksum);

    writefln("%s_direct_p10_ns=%s", name, value.direct.p10);
    writefln("%s_direct_p50_ns=%s", name, value.direct.p50);
    writefln("%s_direct_p90_ns=%s", name, value.direct.p90);

    writefln("%s_inline_p10_ns=%s", name, value.inlineFilter.p10);
    writefln("%s_inline_p50_ns=%s", name, value.inlineFilter.p50);
    writefln("%s_inline_p90_ns=%s", name, value.inlineFilter.p90);
    writefln(
        "%s_inline_over_direct=%.6f",
        name,
        cast(double)value.inlineFilter.p50 / cast(double)value.direct.p50);

    writefln("%s_push_p10_ns=%s", name, value.pushFilter.p10);
    writefln("%s_push_p50_ns=%s", name, value.pushFilter.p50);
    writefln("%s_push_p90_ns=%s", name, value.pushFilter.p90);
    writefln(
        "%s_push_over_direct=%.6f",
        name,
        cast(double)value.pushFilter.p50 / cast(double)value.direct.p50);
    writefln(
        "%s_push_over_inline=%.6f",
        name,
        cast(double)value.pushFilter.p50 /
            cast(double)value.inlineFilter.p50);

    writefln(
        "%s_direct_gc_allocated_bytes=%s",
        name,
        value.direct.gcAllocatedBytes);
    writefln(
        "%s_inline_gc_allocated_bytes=%s",
        name,
        value.inlineFilter.gcAllocatedBytes);
    writefln(
        "%s_push_gc_allocated_bytes=%s",
        name,
        value.pushFilter.gcAllocatedBytes);
    writefln(
        "%s_direct_gc_collections=%s",
        name,
        value.direct.gcCollections);
    writefln(
        "%s_inline_gc_collections=%s",
        name,
        value.inlineFilter.gcCollections);
    writefln(
        "%s_push_gc_collections=%s",
        name,
        value.pushFilter.gcCollections);
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

    writefln("input_bytes=%s", input.length);
    writefln("samples=%s", sampleCount);

    printTiming("id_high", measure!highSelectivity(input));
    printTiming("id_low", measure!lowSelectivity(input));
    printTiming("tag_highway", measure!highway(input));

    return 0;
}
