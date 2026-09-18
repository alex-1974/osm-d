/**
 * Microbenchmark for the production OSMPBF regular Way decode path.
 *
 * The benchmark measures the public `decodeWays` path on deterministic
 * synthetic PrimitiveBlocks. PrimitiveBlock/PrimitiveGroup layout discovery,
 * StringTable indexing, workload generation, correctness validation, sample
 * ordering, sorting and reporting remain outside the timed region. Timed work
 * includes the complete regular-Way semantic preflight, the second production
 * parse/emission pass, borrowed range construction and one of four observable
 * sinks.
 *
 * This is an in-memory CPU/cache microbenchmark. It does not include file I/O,
 * Blob framing, decompression, HeaderBlock processing, node resolution,
 * geometry construction or owned-model/store construction and must not be
 * quoted as end-to-end PBF/editor throughput.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-13
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module benchmark.micro.regular_ways;

import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.info :
    InfoView,
    finalizeInfo,
    mergeInfoMessage;
import osm.io.pbf.tags :
    TagRange,
    TagValidationSummary,
    buildTagRange,
    validateTags;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;
import osm.wire.varint : readSVarint64, readVarint32, readVarint64;
import osm.io.pbf.primitive_block :
    PrimitiveBlockLayout,
    decodePrimitiveBlockLayout;
import osm.io.pbf.primitive_group :
    PrimitiveGroupLayout,
    decodePrimitiveGroupLayout;
import osm.io.pbf.string_table :
    StringRef,
    StringTableView,
    buildStringTableView;
import osm.io.pbf.way :
    WayDecodeSummary,
    WayLocationRange,
    WayLocationValidationSummary,
    WayRefRange,
    WayRefValidationSummary,
    WayView,
    buildWayLocationRange,
    buildWayRefRange,
    decodeWays,
    validateWayLocations,
    validateWayRefs;

import std.algorithm.sorting : sort;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, writefln, writeln;

private enum WorkloadProfile
{
    refOnly,
    typical,
    typicalInfo,
    locations,
    rich,
}

private enum SinkPath
{
    refs,
    tagIds,
    tagBytes,
    locations,
}

private struct DecodeRun
{
    ulong checksum;
    size_t wayCount;
    size_t tagCount;
    size_t refCount;
    size_t locationCount;
    size_t infoCount;
    bool ok;
}

private struct TimingStats
{
    long minimumNanoseconds;
    long p10Nanoseconds;
    long medianNanoseconds;
    long p90Nanoseconds;
    long maximumNanoseconds;
}

private struct BenchResult
{
    TimingStats timings;
    ulong checksum;
    bool ok;
}

private struct Workload
{
    string name;
    ubyte[] blockBytes;
    StringRef[] stringRefs;
    PrimitiveBlockLayout block;
    PrimitiveGroupLayout group;
    StringTableView table;
    size_t wayCount;
    size_t tagCount;
    size_t refCount;
    size_t locationCount;
    size_t infoCount;
    ulong refsChecksum;
    ulong tagIdChecksum;
    ulong tagByteChecksum;
    ulong locationChecksum;
}


version (RegularWayStageBenchmark)
{
    private enum StageKind
    {
        groupScan,
        semanticPreflight,
        prevalidatedEmission,
        fullDecode,
    }

    private struct StageRun
    {
        ulong checksum;
        size_t wayCount;
        size_t tagCount;
        size_t refCount;
        size_t locationCount;
        size_t infoCount;
        bool ok;
    }

    private struct StageWayMessageRef
    {
        const(ubyte)[] bytes;
        size_t rawOffset;
    }

    private struct StageParsedWay
    {
        long id;
        InfoView info;
        TagValidationSummary tags;
        WayRefValidationSummary refs;
        WayLocationValidationSummary locations;
    }

    /** Benchmark-local mirror of the private production WayMessageCursor. */
    private struct StageWayMessageCursor
    {
    private:
        WireCursor _group;

    public:
        this(const(ubyte)[] group) @safe nothrow @nogc
        {
            _group = WireCursor(group);
        }

        bool next(
            out StageWayMessageRef way,
            out bool hasWay,
            out PbfStatus status)
            @safe nothrow @nogc
        {
            way = StageWayMessageRef.init;
            hasWay = false;

            while (!_group.empty)
            {
                FieldHeader field;
                WireStatus wire;
                if (!readFieldHeader(_group, field, wire))
                {
                    status = PbfStatus.fromPrimitiveGroupWire(wire);
                    return false;
                }

                if (field.number == 3 && field.wireType == WireType.lengthDelimited)
                {
                    const(ubyte)[] payload;
                    if (!readLengthDelimited(_group, field.number, payload, wire))
                    {
                        status = PbfStatus.fromPrimitiveGroupWire(wire);
                        return false;
                    }

                    way = StageWayMessageRef(
                        payload,
                        _group.offset - payload.length);
                    hasWay = true;
                    status = PbfStatus.init;
                    return true;
                }

                if (!skipFieldValue(_group, field, wire))
                {
                    status = PbfStatus.fromPrimitiveGroupWire(wire);
                    return false;
                }
            }

            status = PbfStatus.init;
            return true;
        }
    }
}

pragma(inline, true)
private ulong mix(ulong state, ulong value) @safe pure nothrow @nogc
{
    return state ^ (value + 0x9e37_79b9_7f4a_7c15UL + (state << 6) + (state >> 2));
}

pragma(inline, true)
private void consumeInfo(
    ref ulong checksum,
    ref size_t infoCount,
    scope ref InfoView info)
    @safe nothrow @nogc
{
    const present = info.hasVersion || info.hasTimestamp || info.hasChangeset ||
        info.hasUid || info.hasUser || info.hasVisible;
    if (!present)
        return;

    checksum = mix(checksum, cast(ulong)info.hasVersion);
    checksum = mix(checksum, cast(ulong)info.hasTimestamp);
    checksum = mix(checksum, cast(ulong)info.hasChangeset);
    checksum = mix(checksum, cast(ulong)info.hasUid);
    checksum = mix(checksum, cast(ulong)info.hasUser);
    checksum = mix(checksum, cast(ulong)info.hasVisible);

    if (info.hasVersion)
        checksum = mix(checksum, cast(ulong)info.version_);
    if (info.hasTimestamp)
    {
        checksum = mix(checksum, cast(ulong)info.timestampValue);
        checksum = mix(checksum, cast(ulong)info.timestampMillis);
    }
    if (info.hasChangeset)
        checksum = mix(checksum, cast(ulong)info.changeset);
    if (info.hasUid)
        checksum = mix(checksum, cast(ulong)info.uid);
    if (info.hasUser)
    {
        checksum = mix(checksum, info.userSid);
        checksum = mix(checksum, info.user.length);
        if (info.user.length != 0)
        {
            checksum = mix(checksum, info.user[0]);
            checksum = mix(checksum, info.user[$ - 1]);
        }
    }
    if (info.hasVisible)
        checksum = mix(checksum, cast(ulong)info.visible);

    ++infoCount;
}

pragma(inline, true)
private void consumeRefs(
    ref ulong checksum,
    ref size_t refCount,
    scope ref WayView way)
    @safe nothrow @nogc
{
    auto refs = way.refs;
    while (!refs.empty)
    {
        checksum = mix(checksum, cast(ulong)refs.front);
        ++refCount;
        refs.popFront();
    }
}

private struct RefSink
{
    ulong checksum;
    size_t wayCount;
    size_t refCount;
    size_t infoCount;

    void put(scope ref WayView way) @safe nothrow @nogc
    {
        checksum = mix(checksum, cast(ulong)way.id);
        consumeInfo(checksum, infoCount, way.info);
        consumeRefs(checksum, refCount, way);
        ++wayCount;
    }
}

private struct TagIdSink
{
    ulong checksum;
    size_t wayCount;
    size_t tagCount;
    size_t refCount;
    size_t infoCount;

    void put(scope ref WayView way) @safe nothrow @nogc
    {
        checksum = mix(checksum, cast(ulong)way.id);
        consumeInfo(checksum, infoCount, way.info);
        consumeRefs(checksum, refCount, way);

        auto tags = way.tags;
        while (!tags.empty)
        {
            const tag = tags.front;
            checksum = mix(checksum, tag.keySid);
            checksum = mix(checksum, tag.valueSid);
            ++tagCount;
            tags.popFront();
        }

        ++wayCount;
    }
}

private struct TagByteSink
{
    ulong checksum;
    size_t wayCount;
    size_t tagCount;
    size_t refCount;
    size_t infoCount;

    void put(scope ref WayView way) @safe nothrow @nogc
    {
        checksum = mix(checksum, cast(ulong)way.id);
        consumeInfo(checksum, infoCount, way.info);
        consumeRefs(checksum, refCount, way);

        auto tags = way.tags;
        while (!tags.empty)
        {
            const tag = tags.front;
            checksum = mix(checksum, tag.keySid);
            checksum = mix(checksum, tag.valueSid);
            checksum = mix(checksum, tag.key.length);
            checksum = mix(checksum, tag.value.length);

            if (tag.key.length != 0)
            {
                checksum = mix(checksum, tag.key[0]);
                checksum = mix(checksum, tag.key[$ - 1]);
            }
            if (tag.value.length != 0)
            {
                checksum = mix(checksum, tag.value[0]);
                checksum = mix(checksum, tag.value[$ - 1]);
            }

            ++tagCount;
            tags.popFront();
        }

        ++wayCount;
    }
}

private struct LocationSink
{
    ulong checksum;
    size_t wayCount;
    size_t refCount;
    size_t locationCount;
    size_t infoCount;

    void put(scope ref WayView way) @safe nothrow @nogc
    {
        checksum = mix(checksum, cast(ulong)way.id);
        consumeInfo(checksum, infoCount, way.info);
        consumeRefs(checksum, refCount, way);

        auto locations = way.locations;
        while (!locations.empty)
        {
            const location = locations.front;
            checksum = mix(checksum, cast(ulong)location.latNano);
            checksum = mix(checksum, cast(ulong)location.lonNano);
            ++locationCount;
            locations.popFront();
        }

        ++wayCount;
    }
}

private DecodeRun decodeRefs(ref const Workload workload)
    @safe nothrow @nogc
{
    RefSink sink;
    WayDecodeSummary summary;
    PbfStatus status;
    const ok = decodeWays(
        workload.block,
        workload.group,
        workload.table,
        sink,
        summary,
        status);

    return DecodeRun(
        sink.checksum,
        summary.wayCount,
        summary.tagCount,
        summary.refCount,
        summary.locationCount,
        sink.infoCount,
        ok && sink.wayCount == summary.wayCount &&
            sink.refCount == summary.refCount);
}

private DecodeRun decodeTagIds(ref const Workload workload)
    @safe nothrow @nogc
{
    TagIdSink sink;
    WayDecodeSummary summary;
    PbfStatus status;
    const ok = decodeWays(
        workload.block,
        workload.group,
        workload.table,
        sink,
        summary,
        status);

    return DecodeRun(
        sink.checksum,
        summary.wayCount,
        summary.tagCount,
        summary.refCount,
        summary.locationCount,
        sink.infoCount,
        ok && sink.wayCount == summary.wayCount &&
            sink.refCount == summary.refCount &&
            sink.tagCount == summary.tagCount);
}

private DecodeRun decodeTagBytes(ref const Workload workload)
    @safe nothrow @nogc
{
    TagByteSink sink;
    WayDecodeSummary summary;
    PbfStatus status;
    const ok = decodeWays(
        workload.block,
        workload.group,
        workload.table,
        sink,
        summary,
        status);

    return DecodeRun(
        sink.checksum,
        summary.wayCount,
        summary.tagCount,
        summary.refCount,
        summary.locationCount,
        sink.infoCount,
        ok && sink.wayCount == summary.wayCount &&
            sink.refCount == summary.refCount &&
            sink.tagCount == summary.tagCount);
}

private DecodeRun decodeLocations(ref const Workload workload)
    @safe nothrow @nogc
{
    LocationSink sink;
    WayDecodeSummary summary;
    PbfStatus status;
    const ok = decodeWays(
        workload.block,
        workload.group,
        workload.table,
        sink,
        summary,
        status);

    return DecodeRun(
        sink.checksum,
        summary.wayCount,
        summary.tagCount,
        summary.refCount,
        summary.locationCount,
        sink.infoCount,
        ok && sink.wayCount == summary.wayCount &&
            sink.refCount == summary.refCount &&
            sink.locationCount == summary.locationCount);
}

private ulong expectedChecksum(ref const Workload workload, SinkPath path)
    @safe pure nothrow @nogc
{
    final switch (path)
    {
    case SinkPath.refs:
        return workload.refsChecksum;
    case SinkPath.tagIds:
        return workload.tagIdChecksum;
    case SinkPath.tagBytes:
        return workload.tagByteChecksum;
    case SinkPath.locations:
        return workload.locationChecksum;
    }
}

private DecodeRun decodeSelected(ref const Workload workload, SinkPath path)
    @safe nothrow @nogc
{
    final switch (path)
    {
    case SinkPath.refs:
        return decodeRefs(workload);
    case SinkPath.tagIds:
        return decodeTagIds(workload);
    case SinkPath.tagBytes:
        return decodeTagBytes(workload);
    case SinkPath.locations:
        return decodeLocations(workload);
    }
}

private bool validateRun(
    ref const Workload workload,
    SinkPath path,
    uint iterations,
    const DecodeRun aggregate)
    @safe pure nothrow @nogc
{
    return aggregate.ok &&
        aggregate.wayCount == workload.wayCount * cast(size_t)iterations &&
        aggregate.tagCount == workload.tagCount * cast(size_t)iterations &&
        aggregate.refCount == workload.refCount * cast(size_t)iterations &&
        aggregate.locationCount == workload.locationCount * cast(size_t)iterations &&
        aggregate.infoCount == workload.infoCount * cast(size_t)iterations &&
        aggregate.checksum == expectedChecksum(workload, path) * iterations;
}

private bool warmup(
    ref const Workload workload,
    SinkPath path,
    uint iterations)
    @safe nothrow @nogc
{
    foreach (_; 0 .. iterations)
    {
        const run = decodeSelected(workload, path);
        if (!run.ok ||
            run.wayCount != workload.wayCount ||
            run.tagCount != workload.tagCount ||
            run.refCount != workload.refCount ||
            run.locationCount != workload.locationCount ||
            run.infoCount != workload.infoCount ||
            run.checksum != expectedChecksum(workload, path))
            return false;
    }
    return true;
}

private long timePath(
    ref const Workload workload,
    SinkPath path,
    uint iterations,
    out ulong observableChecksum)
    @system
{
    auto stopwatch = StopWatch(AutoStart.yes);
    ulong aggregateChecksum;
    size_t aggregateWays;
    size_t aggregateTags;
    size_t aggregateRefs;
    size_t aggregateLocations;
    size_t aggregateInfo;
    bool ok = true;

    foreach (_; 0 .. iterations)
    {
        const run = decodeSelected(workload, path);
        aggregateChecksum += run.checksum;
        aggregateWays += run.wayCount;
        aggregateTags += run.tagCount;
        aggregateRefs += run.refCount;
        aggregateLocations += run.locationCount;
        aggregateInfo += run.infoCount;
        ok = ok && run.ok;
    }

    stopwatch.stop();
    observableChecksum = aggregateChecksum;

    const aggregate = DecodeRun(
        aggregateChecksum,
        aggregateWays,
        aggregateTags,
        aggregateRefs,
        aggregateLocations,
        aggregateInfo,
        ok);
    if (!validateRun(workload, path, iterations, aggregate))
        return -1;

    return stopwatch.peek.total!"nsecs";
}

private long percentile(scope const(long)[] sortedTimings, uint percent)
    @safe pure nothrow @nogc
{
    if (sortedTimings.length == 0)
        return 0;
    const numerator = (sortedTimings.length - 1) * percent + 50;
    return sortedTimings[cast(size_t)(numerator / 100)];
}

private BenchResult summarize(long[] timings, ulong checksum)
{
    if (timings.length == 0)
        return BenchResult(TimingStats.init, checksum, false);

    sort(timings);
    return BenchResult(
        TimingStats(
            timings[0],
            percentile(timings, 10),
            percentile(timings, 50),
            percentile(timings, 90),
            timings[$ - 1]),
        checksum,
        true);
}

private void storeTiming(
    SinkPath path,
    uint sample,
    long elapsed,
    ulong observed,
    long[] refTimings,
    long[] tagIdTimings,
    long[] tagByteTimings,
    long[] locationTimings,
    ref ulong refChecksum,
    ref ulong tagIdChecksum,
    ref ulong tagByteChecksum,
    ref ulong locationChecksum)
    @safe nothrow @nogc
{
    final switch (path)
    {
    case SinkPath.refs:
        refTimings[sample] = elapsed;
        refChecksum += observed ^ cast(ulong)sample;
        break;
    case SinkPath.tagIds:
        tagIdTimings[sample] = elapsed;
        tagIdChecksum += observed ^ cast(ulong)sample;
        break;
    case SinkPath.tagBytes:
        tagByteTimings[sample] = elapsed;
        tagByteChecksum += observed ^ cast(ulong)sample;
        break;
    case SinkPath.locations:
        locationTimings[sample] = elapsed;
        locationChecksum += observed ^ cast(ulong)sample;
        break;
    }
}

private bool measureAll(
    ref const Workload workload,
    uint iterations,
    uint samples,
    uint warmupIterations,
    out BenchResult refs,
    out BenchResult tagIds,
    out BenchResult tagBytes,
    out BenchResult locations)
    @system
{
    if (!warmup(workload, SinkPath.refs, warmupIterations) ||
        !warmup(workload, SinkPath.tagIds, warmupIterations) ||
        !warmup(workload, SinkPath.tagBytes, warmupIterations) ||
        !warmup(workload, SinkPath.locations, warmupIterations))
        return false;

    auto refTimings = new long[samples];
    auto tagIdTimings = new long[samples];
    auto tagByteTimings = new long[samples];
    auto locationTimings = new long[samples];
    ulong refChecksum;
    ulong tagIdChecksum;
    ulong tagByteChecksum;
    ulong locationChecksum;

    static immutable SinkPath[4][24] orders = [
        [SinkPath.refs, SinkPath.tagIds, SinkPath.tagBytes, SinkPath.locations],
        [SinkPath.refs, SinkPath.tagIds, SinkPath.locations, SinkPath.tagBytes],
        [SinkPath.refs, SinkPath.tagBytes, SinkPath.tagIds, SinkPath.locations],
        [SinkPath.refs, SinkPath.tagBytes, SinkPath.locations, SinkPath.tagIds],
        [SinkPath.refs, SinkPath.locations, SinkPath.tagIds, SinkPath.tagBytes],
        [SinkPath.refs, SinkPath.locations, SinkPath.tagBytes, SinkPath.tagIds],
        [SinkPath.tagIds, SinkPath.refs, SinkPath.tagBytes, SinkPath.locations],
        [SinkPath.tagIds, SinkPath.refs, SinkPath.locations, SinkPath.tagBytes],
        [SinkPath.tagIds, SinkPath.tagBytes, SinkPath.refs, SinkPath.locations],
        [SinkPath.tagIds, SinkPath.tagBytes, SinkPath.locations, SinkPath.refs],
        [SinkPath.tagIds, SinkPath.locations, SinkPath.refs, SinkPath.tagBytes],
        [SinkPath.tagIds, SinkPath.locations, SinkPath.tagBytes, SinkPath.refs],
        [SinkPath.tagBytes, SinkPath.refs, SinkPath.tagIds, SinkPath.locations],
        [SinkPath.tagBytes, SinkPath.refs, SinkPath.locations, SinkPath.tagIds],
        [SinkPath.tagBytes, SinkPath.tagIds, SinkPath.refs, SinkPath.locations],
        [SinkPath.tagBytes, SinkPath.tagIds, SinkPath.locations, SinkPath.refs],
        [SinkPath.tagBytes, SinkPath.locations, SinkPath.refs, SinkPath.tagIds],
        [SinkPath.tagBytes, SinkPath.locations, SinkPath.tagIds, SinkPath.refs],
        [SinkPath.locations, SinkPath.refs, SinkPath.tagIds, SinkPath.tagBytes],
        [SinkPath.locations, SinkPath.refs, SinkPath.tagBytes, SinkPath.tagIds],
        [SinkPath.locations, SinkPath.tagIds, SinkPath.refs, SinkPath.tagBytes],
        [SinkPath.locations, SinkPath.tagIds, SinkPath.tagBytes, SinkPath.refs],
        [SinkPath.locations, SinkPath.tagBytes, SinkPath.refs, SinkPath.tagIds],
        [SinkPath.locations, SinkPath.tagBytes, SinkPath.tagIds, SinkPath.refs],
    ];

    foreach (sample; 0 .. samples)
    {
        const order = orders[sample % orders.length];
        foreach (path; order)
        {
            ulong observed;
            const elapsed = timePath(workload, path, iterations, observed);
            if (elapsed < 0)
                return false;
            storeTiming(
                path,
                sample,
                elapsed,
                observed,
                refTimings,
                tagIdTimings,
                tagByteTimings,
                locationTimings,
                refChecksum,
                tagIdChecksum,
                tagByteChecksum,
                locationChecksum);
        }
    }

    refs = summarize(refTimings, refChecksum);
    tagIds = summarize(tagIdTimings, tagIdChecksum);
    tagBytes = summarize(tagByteTimings, tagByteChecksum);
    locations = summarize(locationTimings, locationChecksum);
    return refs.ok && tagIds.ok && tagBytes.ok && locations.ok;
}

private BenchResult measureSingle(
    ref const Workload workload,
    SinkPath path,
    uint iterations,
    uint samples,
    uint warmupIterations)
    @system
{
    if (!warmup(workload, path, warmupIterations))
        return BenchResult.init;

    auto timings = new long[samples];
    ulong observableChecksum;
    foreach (sample; 0 .. samples)
    {
        ulong observed;
        const elapsed = timePath(workload, path, iterations, observed);
        if (elapsed < 0)
            return BenchResult.init;
        timings[sample] = elapsed;
        observableChecksum += observed ^ cast(ulong)sample;
    }
    return summarize(timings, observableChecksum);
}

private string pathName(SinkPath path) @safe pure nothrow
{
    final switch (path)
    {
    case SinkPath.refs:
        return "refs";
    case SinkPath.tagIds:
        return "tag-ids";
    case SinkPath.tagBytes:
        return "tag-bytes";
    case SinkPath.locations:
        return "locations";
    }
}

private void report(
    SinkPath path,
    ref const Workload workload,
    uint iterations,
    const BenchResult result)
{
    const totalWays = cast(double)workload.wayCount * iterations;
    const totalGroupBytes = cast(double)workload.group.raw.length * iterations;
    const medianSeconds = cast(double)result.timings.medianNanoseconds /
        1_000_000_000.0;
    const medianNsPerWay = cast(double)result.timings.medianNanoseconds / totalWays;
    const p10NsPerWay = cast(double)result.timings.p10Nanoseconds / totalWays;
    const p90NsPerWay = cast(double)result.timings.p90Nanoseconds / totalWays;
    const minNsPerWay = cast(double)result.timings.minimumNanoseconds / totalWays;
    const maxNsPerWay = cast(double)result.timings.maximumNanoseconds / totalWays;
    const megaWaysPerSecond = totalWays / medianSeconds / 1_000_000.0;
    const mebiGroupBytesPerSecond = totalGroupBytes / medianSeconds / (1024.0 * 1024.0);
    const spreadPercent = result.timings.medianNanoseconds == 0
        ? 0.0
        : cast(double)(result.timings.p90Nanoseconds - result.timings.p10Nanoseconds) /
            result.timings.medianNanoseconds * 100.0;

    writefln(
        "%-13s %-10s p50=%8.3f ns/way  %7.2f Mway/s %8.2f MiB/s(group)  " ~
        "p10=%8.3f p90=%8.3f Δ80=%5.1f%%  min=%8.3f max=%8.3f  checksum=%016x",
        workload.name,
        pathName(path),
        medianNsPerWay,
        megaWaysPerSecond,
        mebiGroupBytesPerSecond,
        p10NsPerWay,
        p90NsPerWay,
        spreadPercent,
        minNsPerWay,
        maxNsPerWay,
        result.checksum);
}

private bool parseProfile(string name, out WorkloadProfile profile)
    @safe pure nothrow
{
    switch (name)
    {
    case "ref-only": profile = WorkloadProfile.refOnly; return true;
    case "typical": profile = WorkloadProfile.typical; return true;
    case "typical-info": profile = WorkloadProfile.typicalInfo; return true;
    case "locations": profile = WorkloadProfile.locations; return true;
    case "rich": profile = WorkloadProfile.rich; return true;
    default: profile = WorkloadProfile.init; return false;
    }
}

private bool parsePath(string name, out SinkPath path)
    @safe pure nothrow
{
    switch (name)
    {
    case "refs":
    case "references":
        path = SinkPath.refs;
        return true;
    case "tag-ids":
    case "tags":
        path = SinkPath.tagIds;
        return true;
    case "tag-bytes":
    case "strings":
        path = SinkPath.tagBytes;
        return true;
    case "locations":
    case "coords":
        path = SinkPath.locations;
        return true;
    default:
        path = SinkPath.init;
        return false;
    }
}

private string profileName(WorkloadProfile profile) @safe pure nothrow
{
    final switch (profile)
    {
    case WorkloadProfile.refOnly: return "ref-only";
    case WorkloadProfile.typical: return "typical";
    case WorkloadProfile.typicalInfo: return "typical-info";
    case WorkloadProfile.locations: return "locations";
    case WorkloadProfile.rich: return "rich";
    }
}

private size_t refsPerWay(WorkloadProfile profile) @safe pure nothrow @nogc
{
    final switch (profile)
    {
    case WorkloadProfile.refOnly:
    case WorkloadProfile.typical:
    case WorkloadProfile.typicalInfo:
    case WorkloadProfile.locations:
        return 8;
    case WorkloadProfile.rich:
        return 32;
    }
}

private size_t tagsPerWay(WorkloadProfile profile) @safe pure nothrow @nogc
{
    final switch (profile)
    {
    case WorkloadProfile.refOnly:
        return 0;
    case WorkloadProfile.typical:
    case WorkloadProfile.typicalInfo:
    case WorkloadProfile.locations:
        return 2;
    case WorkloadProfile.rich:
        return 8;
    }
}

private bool hasInfo(WorkloadProfile profile) @safe pure nothrow @nogc
{
    return profile == WorkloadProfile.typicalInfo ||
        profile == WorkloadProfile.locations ||
        profile == WorkloadProfile.rich;
}

private bool hasLocations(WorkloadProfile profile) @safe pure nothrow @nogc
{
    return profile == WorkloadProfile.locations ||
        profile == WorkloadProfile.rich;
}

private long wayId(size_t wayIndex) @safe pure nothrow @nogc
{
    return 2_000_000_000L + cast(long)wayIndex;
}

private long nodeRef(size_t wayIndex, size_t refIndex) @safe pure nothrow @nogc
{
    return 1_000_000_000L + cast(long)(wayIndex * 64 + refIndex * 3);
}

private long latitudeGrid(size_t wayIndex, size_t refIndex)
    @safe pure nothrow @nogc
{
    return 480_000_000L + cast(long)((wayIndex * 5) & 4095) + cast(long)refIndex;
}

private long longitudeGrid(size_t wayIndex, size_t refIndex)
    @safe pure nothrow @nogc
{
    return 160_000_000L + cast(long)((wayIndex * 7) & 4095) + cast(long)(refIndex * 2);
}

private ulong zigZag64(long value) @safe pure nothrow @nogc
{
    return (cast(ulong)value << 1) ^ cast(ulong)(value >> 63);
}

private void appendVarint(ref ubyte[] output, ulong value)
{
    while (value >= 0x80)
    {
        output ~= cast(ubyte)((value & 0x7f) | 0x80);
        value >>= 7;
    }
    output ~= cast(ubyte)value;
}

private void appendFieldKey(ref ubyte[] output, uint fieldNumber, uint wireType)
{
    appendVarint(output, (cast(ulong)fieldNumber << 3) | wireType);
}

private void appendLengthDelimited(
    ref ubyte[] output,
    uint fieldNumber,
    scope const(ubyte)[] payload)
{
    appendFieldKey(output, fieldNumber, 2);
    appendVarint(output, payload.length);
    output ~= payload;
}

private void appendString(ref ubyte[] stringTable, string value)
{
    appendLengthDelimited(
        stringTable,
        1,
        cast(const(ubyte)[])value);
}

private void appendInfo(ref ubyte[] info, size_t wayIndex)
{
    appendFieldKey(info, 1, 0);
    appendVarint(info, 1 + (wayIndex & 7));

    appendFieldKey(info, 2, 0);
    appendVarint(info, 1_700_000_000UL + (wayIndex % 86_400));

    appendFieldKey(info, 3, 0);
    appendVarint(info, 20_000_000UL + wayIndex);

    appendFieldKey(info, 4, 0);
    appendVarint(info, 1_000 + (wayIndex & 1023));

    appendFieldKey(info, 5, 0);
    appendVarint(info, 17);

    appendFieldKey(info, 6, 0);
    appendVarint(info, 1);
}

private void appendRefDeltas(
    ref ubyte[] refs,
    size_t wayIndex,
    size_t count)
{
    long previous;
    foreach (refIndex; 0 .. count)
    {
        const absolute = nodeRef(wayIndex, refIndex);
        const delta = absolute - previous;
        appendVarint(refs, zigZag64(delta));
        previous = absolute;
    }
}

private void appendLocationDeltas(
    ref ubyte[] lats,
    ref ubyte[] lons,
    size_t wayIndex,
    size_t count)
{
    long previousLat;
    long previousLon;
    foreach (refIndex; 0 .. count)
    {
        const lat = latitudeGrid(wayIndex, refIndex);
        const lon = longitudeGrid(wayIndex, refIndex);
        appendVarint(lats, zigZag64(lat - previousLat));
        appendVarint(lons, zigZag64(lon - previousLon));
        previousLat = lat;
        previousLon = lon;
    }
}

private bool buildWorkload(
    WorkloadProfile profile,
    size_t wayCount,
    out Workload workload)
    @system
{
    workload = Workload.init;
    workload.name = profileName(profile);
    workload.wayCount = wayCount;

    static immutable string[18] strings = [
        "",
        "highway", "residential",
        "name", "Main Street",
        "surface", "asphalt",
        "lit", "yes",
        "maxspeed", "50",
        "lanes", "2",
        "access", "destination",
        "source", "survey",
        "benchmark-user",
    ];

    ubyte[] stringTable;
    foreach (value; strings)
        appendString(stringTable, value);

    ubyte[] group;
    ubyte[] way;
    ubyte[] keys;
    ubyte[] vals;
    ubyte[] info;
    ubyte[] refs;
    ubyte[] lats;
    ubyte[] lons;
    size_t totalTags;
    size_t totalRefs;
    size_t totalLocations;
    size_t totalInfo;

    foreach (i; 0 .. wayCount)
    {
        way.length = 0;
        keys.length = 0;
        vals.length = 0;
        info.length = 0;
        refs.length = 0;
        lats.length = 0;
        lons.length = 0;

        appendFieldKey(way, 1, 0);
        appendVarint(way, cast(ulong)wayId(i));

        const tags = tagsPerWay(profile);
        totalTags += tags;
        foreach (tagIndex; 0 .. tags)
        {
            const pair = (i + tagIndex) & 7;
            const keySid = 1 + pair * 2;
            const valueSid = keySid + 1;
            appendVarint(keys, keySid);
            appendVarint(vals, valueSid);
        }
        if (tags != 0)
        {
            appendLengthDelimited(way, 2, keys);
            appendLengthDelimited(way, 3, vals);
        }

        if (hasInfo(profile))
        {
            appendInfo(info, i);
            appendLengthDelimited(way, 4, info);
            ++totalInfo;
        }

        const refCount = refsPerWay(profile);
        totalRefs += refCount;
        appendRefDeltas(refs, i, refCount);
        appendLengthDelimited(way, 8, refs);

        if (hasLocations(profile))
        {
            appendLocationDeltas(lats, lons, i, refCount);
            appendLengthDelimited(way, 9, lats);
            appendLengthDelimited(way, 10, lons);
            totalLocations += refCount;
        }

        appendLengthDelimited(group, 3, way);
    }

    workload.tagCount = totalTags;
    workload.refCount = totalRefs;
    workload.locationCount = totalLocations;
    workload.infoCount = totalInfo;

    ubyte[] blockBytes;
    appendLengthDelimited(blockBytes, 1, stringTable);
    appendLengthDelimited(blockBytes, 2, group);
    workload.blockBytes = blockBytes;

    PbfStatus status;
    if (!decodePrimitiveBlockLayout(workload.blockBytes, workload.block, status))
        return false;

    workload.stringRefs = new StringRef[workload.block.stringCount];
    if (!buildStringTableView(
        workload.block,
        workload.stringRefs,
        workload.table,
        status))
        return false;

    auto groups = workload.block.primitiveGroups;
    if (groups.empty)
        return false;
    const groupRef = groups.front;
    groups.popFront();
    if (!groups.empty)
        return false;

    if (!decodePrimitiveGroupLayout(groupRef.bytes, workload.group, status))
        return false;

    if (workload.group.wayOccurrences != wayCount)
        return false;

    const refRun = decodeRefs(workload);
    const tagIds = decodeTagIds(workload);
    const tagBytes = decodeTagBytes(workload);
    const locations = decodeLocations(workload);
    if (!refRun.ok || !tagIds.ok || !tagBytes.ok || !locations.ok ||
        refRun.wayCount != wayCount ||
        refRun.tagCount != totalTags ||
        refRun.refCount != totalRefs ||
        refRun.locationCount != totalLocations ||
        refRun.infoCount != totalInfo ||
        tagIds.wayCount != wayCount ||
        tagIds.tagCount != totalTags ||
        tagIds.refCount != totalRefs ||
        tagIds.locationCount != totalLocations ||
        tagIds.infoCount != totalInfo ||
        tagBytes.wayCount != wayCount ||
        tagBytes.tagCount != totalTags ||
        tagBytes.refCount != totalRefs ||
        tagBytes.locationCount != totalLocations ||
        tagBytes.infoCount != totalInfo ||
        locations.wayCount != wayCount ||
        locations.tagCount != totalTags ||
        locations.refCount != totalRefs ||
        locations.locationCount != totalLocations ||
        locations.infoCount != totalInfo)
        return false;

    workload.refsChecksum = refRun.checksum;
    workload.tagIdChecksum = tagIds.checksum;
    workload.tagByteChecksum = tagBytes.checksum;
    workload.locationChecksum = locations.checksum;
    return true;
}

private bool runWorkload(
    ref const Workload workload,
    bool allPaths,
    SinkPath selectedPath,
    uint iterations,
    uint samples,
    uint warmupIterations)
    @system
{
    writefln(
        "profile=%s ways=%s refs=%s refs/way=%.3f tags=%s tags/way=%.3f " ~
        "info-ways=%s locations=%s locations/way=%.3f group-bytes=%s",
        workload.name,
        workload.wayCount,
        workload.refCount,
        workload.wayCount == 0
            ? 0.0
            : cast(double)workload.refCount / workload.wayCount,
        workload.tagCount,
        workload.wayCount == 0
            ? 0.0
            : cast(double)workload.tagCount / workload.wayCount,
        workload.infoCount,
        workload.locationCount,
        workload.wayCount == 0
            ? 0.0
            : cast(double)workload.locationCount / workload.wayCount,
        workload.group.raw.length);

    if (allPaths)
    {
        BenchResult refs;
        BenchResult tagIds;
        BenchResult tagBytes;
        BenchResult locations;
        if (!measureAll(
            workload,
            iterations,
            samples,
            warmupIterations,
            refs,
            tagIds,
            tagBytes,
            locations))
            return false;

        report(SinkPath.refs, workload, iterations, refs);
        report(SinkPath.tagIds, workload, iterations, tagIds);
        report(SinkPath.tagBytes, workload, iterations, tagBytes);
        report(SinkPath.locations, workload, iterations, locations);
        return true;
    }

    const result = measureSingle(
        workload,
        selectedPath,
        iterations,
        samples,
        warmupIterations);
    if (!result.ok)
        return false;
    report(selectedPath, workload, iterations, result);
    return true;
}

/** Run the regular-Way production microbenchmark. */
private int runRegularMain(string[] args) @system
{
    size_t wayCount = 100_000;
    uint iterations = 3;
    uint samples = 30;
    uint warmupIterations = 2;
    string selectedProfile = "all";
    string selectedPathName = "all";

    auto options = getopt(
        args,
        "ways", "Regular Ways generated for each workload", &wayCount,
        "iterations", "Complete regular-Way decodes per timed sample", &iterations,
        "samples", "Timed samples; robust quantiles are reported", &samples,
        "warmup", "Untimed decodes before measurement", &warmupIterations,
        "profile", "all|ref-only|typical|typical-info|locations|rich", &selectedProfile,
        "path", "all|refs|tag-ids|tag-bytes|locations", &selectedPathName);

    if (options.helpWanted)
    {
        defaultGetoptPrinter(
            "osm-d regular Way microbenchmark",
            options.options);
        return 0;
    }

    if (wayCount == 0 || iterations == 0 || samples == 0)
    {
        stderr.writeln("ways, iterations and samples must all be greater than zero");
        return 2;
    }
    if (samples > 100_000)
    {
        stderr.writeln("samples is unreasonably large");
        return 2;
    }

    const allPaths = selectedPathName == "all";
    SinkPath selectedPath;
    if (!allPaths && !parsePath(selectedPathName, selectedPath))
    {
        stderr.writefln("unknown path: %s", selectedPathName);
        return 2;
    }

    writeln("osm-d regular Way microbenchmark");
    writefln("compiler: %s (%s)", __VENDOR__, __VERSION__);
    writefln(
        "ways/profile: %s  iterations/sample: %s  samples: %s  warmup: %s",
        wayCount,
        iterations,
        samples,
        warmupIterations);
    if (allPaths)
        writeln("ordering: rotating all 24 permutations of the four sink paths");
    else
        writefln("ordering: single path (%s)", selectedPathName);
    writeln("statistics: min, p10, p50, p90, max; Δ80=(p90-p10)/p50");
    writeln("timed: production decodeWays full preflight + second parse/emission + selected sink work");
    writeln("excluded: workload generation, block/group layout, StringTable indexing, validation, sorting and reporting");
    writeln("MiB/s(group) is serialized PrimitiveGroup memory throughput, not compressed PBF I/O");
    writeln();

    static immutable WorkloadProfile[5] allProfiles = [
        WorkloadProfile.refOnly,
        WorkloadProfile.typical,
        WorkloadProfile.typicalInfo,
        WorkloadProfile.locations,
        WorkloadProfile.rich,
    ];

    if (selectedProfile == "all")
    {
        foreach (profile; allProfiles)
        {
            Workload workload;
            if (!buildWorkload(profile, wayCount, workload))
            {
                stderr.writefln("failed to build/validate profile: %s", profileName(profile));
                return 3;
            }
            if (!runWorkload(
                workload,
                allPaths,
                selectedPath,
                iterations,
                samples,
                warmupIterations))
            {
                stderr.writefln("benchmark consistency failure: %s", workload.name);
                return 3;
            }
            writeln();
        }
        return 0;
    }

    WorkloadProfile profile;
    if (!parseProfile(selectedProfile, profile))
    {
        stderr.writefln("unknown profile: %s", selectedProfile);
        return 2;
    }

    Workload workload;
    if (!buildWorkload(profile, wayCount, workload))
    {
        stderr.writefln("failed to build/validate profile: %s", selectedProfile);
        return 3;
    }
    if (!runWorkload(
        workload,
        allPaths,
        selectedPath,
        iterations,
        samples,
        warmupIterations))
    {
        stderr.writefln("benchmark consistency failure: %s", workload.name);
        return 3;
    }
    return 0;
}

version (RegularWayStageBenchmark)
{
    pragma(inline, true)
    private bool stageInfoPresent(ref const InfoView info)
        @safe pure nothrow @nogc
    {
        return info.hasVersion || info.hasTimestamp || info.hasChangeset ||
            info.hasUid || info.hasUser || info.hasVisible;
    }

    private bool stageParseWay(
        ref const PrimitiveBlockLayout block,
        StageWayMessageRef wayRef,
        StringTableView table,
        out StageParsedWay parsed,
        out PbfStatus status)
        @safe nothrow @nogc
    {
        parsed = StageParsedWay.init;
        auto cursor = WireCursor(wayRef.bytes);
        bool hasId;

        while (!cursor.empty)
        {
            FieldHeader field;
            WireStatus wire;
            if (!readFieldHeader(cursor, field, wire))
            {
                status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                return false;
            }

            if (field.number == 1 && field.wireType == WireType.varint)
            {
                ulong raw;
                if (!readVarint64(cursor, raw, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = field.number;
                    status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                    return false;
                }
                parsed.id = cast(long)raw;
                hasId = true;
                continue;
            }

            if (field.number == 4 && field.wireType == WireType.lengthDelimited)
            {
                const(ubyte)[] infoBytes;
                if (!readLengthDelimited(cursor, field.number, infoBytes, wire))
                {
                    status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                    return false;
                }

                const infoOffset =
                    wayRef.rawOffset + cursor.offset - infoBytes.length;
                if (!mergeInfoMessage(
                    infoBytes,
                    infoOffset,
                    parsed.info,
                    status))
                    return false;
                continue;
            }

            if (!skipFieldValue(cursor, field, wire))
            {
                status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                return false;
            }
        }

        if (!hasId)
        {
            status = PbfStatus.failure(
                PbfError.missingWayId,
                wayRef.rawOffset,
                1);
            return false;
        }

        if (!finalizeInfo(block, table, parsed.info, status))
            return false;

        if (!validateTags(
            wayRef.bytes,
            wayRef.rawOffset,
            table,
            parsed.tags,
            status))
            return false;

        if (!validateWayRefs(
            wayRef.bytes,
            wayRef.rawOffset,
            parsed.refs,
            status))
            return false;

        if (!validateWayLocations(
            block,
            wayRef.bytes,
            wayRef.rawOffset,
            parsed.refs.refCount,
            parsed.locations,
            status))
            return false;

        status = PbfStatus.init;
        return true;
    }

    pragma(inline, true)
    private bool stageCountPackedUInt32(
        const(ubyte)[] packedBytes,
        size_t packedBase,
        uint fieldNumber,
        ref size_t count,
        out PbfStatus status)
        @safe nothrow @nogc
    {
        auto packed = WireCursor(packedBytes);
        while (!packed.empty)
        {
            uint ignored;
            WireStatus wire;
            if (!readVarint32(packed, ignored, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = fieldNumber;
                status = PbfStatus.fromTagWire(wire, packedBase);
                return false;
            }
            ++count;
        }
        status = PbfStatus.init;
        return true;
    }

    pragma(inline, true)
    private bool stageCountPackedSInt64(
        const(ubyte)[] packedBytes,
        size_t packedBase,
        uint fieldNumber,
        ref size_t count,
        out PbfStatus status)
        @safe nothrow @nogc
    {
        auto packed = WireCursor(packedBytes);
        while (!packed.empty)
        {
            long ignored;
            WireStatus wire;
            if (!readSVarint64(packed, ignored, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = fieldNumber;
                status = PbfStatus.fromWayWire(wire, packedBase);
                return false;
            }
            ++count;
        }
        status = PbfStatus.init;
        return true;
    }

    /**
     * Benchmark-local model of a second pass over an already prevalidated Way.
     *
     * Values needed for the public WayView are still reconstructed. The pass
     * counts already-valid repeated columns while scanning the message, but it
     * does not repeat StringTable tag validation, checked ref accumulation, or
     * complete LocationsOnWays accumulation/nanodegree validation. Borrowed
     * ranges are then built from the counts established on immutable bytes.
     */
    private bool stageDecodePrevalidatedWay(
        ref const PrimitiveBlockLayout block,
        StageWayMessageRef wayRef,
        StringTableView table,
        out WayView way,
        out size_t tagCount,
        out size_t refCount,
        out size_t locationCount,
        out PbfStatus status)
        @safe nothrow @nogc
    {
        way = WayView.init;
        tagCount = 0;
        refCount = 0;
        locationCount = 0;

        auto cursor = WireCursor(wayRef.bytes);
        bool hasId;
        long id;
        InfoView info;
        size_t latCount;
        size_t lonCount;

        while (!cursor.empty)
        {
            FieldHeader field;
            WireStatus wire;
            if (!readFieldHeader(cursor, field, wire))
            {
                status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                return false;
            }

            if (field.number == 1 && field.wireType == WireType.varint)
            {
                ulong raw;
                if (!readVarint64(cursor, raw, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = field.number;
                    status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                    return false;
                }
                id = cast(long)raw;
                hasId = true;
                continue;
            }

            if (field.number == 2 && field.wireType == WireType.varint)
            {
                uint ignored;
                if (!readVarint32(cursor, ignored, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = field.number;
                    status = PbfStatus.fromTagWire(wire, wayRef.rawOffset);
                    return false;
                }
                ++tagCount;
                continue;
            }

            if (field.number == 2 && field.wireType == WireType.lengthDelimited)
            {
                const(ubyte)[] packedBytes;
                if (!readLengthDelimited(cursor, field.number, packedBytes, wire))
                {
                    status = PbfStatus.fromTagWire(wire, wayRef.rawOffset);
                    return false;
                }
                const packedBase =
                    wayRef.rawOffset + cursor.offset - packedBytes.length;
                if (!stageCountPackedUInt32(
                    packedBytes,
                    packedBase,
                    2,
                    tagCount,
                    status))
                    return false;
                continue;
            }

            if ((field.number == 8 || field.number == 9 || field.number == 10) &&
                field.wireType == WireType.varint)
            {
                long ignored;
                if (!readSVarint64(cursor, ignored, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = field.number;
                    status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                    return false;
                }

                if (field.number == 8)
                    ++refCount;
                else if (field.number == 9)
                    ++latCount;
                else
                    ++lonCount;
                continue;
            }

            if ((field.number == 8 || field.number == 9 || field.number == 10) &&
                field.wireType == WireType.lengthDelimited)
            {
                const(ubyte)[] packedBytes;
                if (!readLengthDelimited(cursor, field.number, packedBytes, wire))
                {
                    status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                    return false;
                }
                const packedBase =
                    wayRef.rawOffset + cursor.offset - packedBytes.length;

                if (field.number == 8)
                {
                    if (!stageCountPackedSInt64(
                        packedBytes,
                        packedBase,
                        8,
                        refCount,
                        status))
                        return false;
                }
                else if (field.number == 9)
                {
                    if (!stageCountPackedSInt64(
                        packedBytes,
                        packedBase,
                        9,
                        latCount,
                        status))
                        return false;
                }
                else
                {
                    if (!stageCountPackedSInt64(
                        packedBytes,
                        packedBase,
                        10,
                        lonCount,
                        status))
                        return false;
                }
                continue;
            }

            if (field.number == 4 && field.wireType == WireType.lengthDelimited)
            {
                const(ubyte)[] infoBytes;
                if (!readLengthDelimited(cursor, field.number, infoBytes, wire))
                {
                    status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                    return false;
                }

                const infoOffset =
                    wayRef.rawOffset + cursor.offset - infoBytes.length;
                if (!mergeInfoMessage(
                    infoBytes,
                    infoOffset,
                    info,
                    status))
                    return false;
                continue;
            }

            if (!skipFieldValue(cursor, field, wire))
            {
                status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                return false;
            }
        }

        if (!hasId)
        {
            status = PbfStatus.failure(
                PbfError.missingWayId,
                wayRef.rawOffset,
                1);
            return false;
        }

        if ((latCount != 0 || lonCount != 0) &&
            (latCount != refCount || lonCount != refCount))
        {
            status = PbfStatus.failure(
                PbfError.wayLocationColumnLengthMismatch,
                wayRef.rawOffset,
                latCount != refCount ? 9 : 10);
            return false;
        }

        if (!finalizeInfo(block, table, info, status))
            return false;

        TagValidationSummary tagSummary;
        tagSummary.keyCount = tagCount;
        tagSummary.valueCount = tagCount;

        TagRange tags;
        if (!buildTagRange(
            wayRef.bytes,
            wayRef.rawOffset,
            table,
            tagSummary,
            tags,
            status))
            return false;

        WayRefValidationSummary refSummary;
        refSummary.refCount = refCount;
        WayRefRange refs;
        if (!buildWayRefRange(
            wayRef.bytes,
            wayRef.rawOffset,
            refSummary,
            refs,
            status))
            return false;

        WayLocationValidationSummary locationSummary;
        locationSummary.latCount = latCount;
        locationSummary.lonCount = lonCount;
        WayLocationRange locations;
        if (!buildWayLocationRange(
            block,
            wayRef.bytes,
            wayRef.rawOffset,
            locationSummary,
            locations,
            status))
            return false;

        locationCount = latCount;
        way = WayView(
            id,
            tags,
            refs,
            locations,
            info,
            wayRef.bytes,
            wayRef.rawOffset);
        status = PbfStatus.init;
        return true;
    }

    private StageRun runGroupScan(ref const Workload workload)
        @safe nothrow @nogc
    {
        size_t wayCount;
        auto ways = StageWayMessageCursor(workload.group.raw);
        PbfStatus status;

        while (true)
        {
            StageWayMessageRef wayRef;
            bool hasWay;
            if (!ways.next(wayRef, hasWay, status))
                return StageRun.init;
            if (!hasWay)
                break;
            ++wayCount;
        }

        const ok = wayCount == workload.group.wayOccurrences;
        return StageRun(
            mix(0, cast(ulong)wayCount),
            wayCount,
            0,
            0,
            0,
            0,
            ok);
    }

    private StageRun runSemanticPreflight(ref const Workload workload)
        @safe nothrow @nogc
    {
        size_t wayCount;
        size_t tagCount;
        size_t refCount;
        size_t locationCount;
        size_t infoCount;
        auto ways = StageWayMessageCursor(workload.group.raw);
        PbfStatus status;

        while (true)
        {
            StageWayMessageRef wayRef;
            bool hasWay;
            if (!ways.next(wayRef, hasWay, status))
                return StageRun.init;
            if (!hasWay)
                break;

            StageParsedWay parsed;
            if (!stageParseWay(
                workload.block,
                wayRef,
                workload.table,
                parsed,
                status))
                return StageRun.init;

            ++wayCount;
            tagCount += parsed.tags.tagCount;
            refCount += parsed.refs.refCount;
            if (parsed.locations.hasLocations)
                locationCount += parsed.locations.latCount;
            if (stageInfoPresent(parsed.info))
                ++infoCount;
        }

        const ok = wayCount == workload.wayCount &&
            tagCount == workload.tagCount &&
            refCount == workload.refCount &&
            locationCount == workload.locationCount &&
            infoCount == workload.infoCount;
        ulong checksum;
        checksum = mix(checksum, cast(ulong)wayCount);
        checksum = mix(checksum, cast(ulong)tagCount);
        checksum = mix(checksum, cast(ulong)refCount);
        checksum = mix(checksum, cast(ulong)locationCount);
        checksum = mix(checksum, cast(ulong)infoCount);
        return StageRun(
            checksum,
            wayCount,
            tagCount,
            refCount,
            locationCount,
            infoCount,
            ok);
    }

    private StageRun runPrevalidatedEmission(ref const Workload workload)
        @safe nothrow @nogc
    {
        RefSink sink;
        size_t tagCount;
        size_t refCount;
        size_t locationCount;
        auto ways = StageWayMessageCursor(workload.group.raw);
        PbfStatus status;

        while (true)
        {
            StageWayMessageRef wayRef;
            bool hasWay;
            if (!ways.next(wayRef, hasWay, status))
                return StageRun.init;
            if (!hasWay)
                break;

            WayView way;
            size_t wayTags;
            size_t wayRefs;
            size_t wayLocations;
            if (!stageDecodePrevalidatedWay(
                workload.block,
                wayRef,
                workload.table,
                way,
                wayTags,
                wayRefs,
                wayLocations,
                status))
                return StageRun.init;

            sink.put(way);
            tagCount += wayTags;
            refCount += wayRefs;
            locationCount += wayLocations;
        }

        const ok = sink.wayCount == workload.wayCount &&
            tagCount == workload.tagCount &&
            refCount == workload.refCount &&
            sink.refCount == workload.refCount &&
            locationCount == workload.locationCount &&
            sink.infoCount == workload.infoCount;
        return StageRun(
            sink.checksum,
            sink.wayCount,
            tagCount,
            refCount,
            locationCount,
            sink.infoCount,
            ok);
    }

    private StageRun runFullDecode(ref const Workload workload)
        @safe nothrow @nogc
    {
        const decoded = decodeRefs(workload);
        return StageRun(
            decoded.checksum,
            decoded.wayCount,
            decoded.tagCount,
            decoded.refCount,
            decoded.locationCount,
            decoded.infoCount,
            decoded.ok);
    }

    private StageRun runStage(ref const Workload workload, StageKind stage)
        @safe nothrow @nogc
    {
        final switch (stage)
        {
        case StageKind.groupScan:
            return runGroupScan(workload);
        case StageKind.semanticPreflight:
            return runSemanticPreflight(workload);
        case StageKind.prevalidatedEmission:
            return runPrevalidatedEmission(workload);
        case StageKind.fullDecode:
            return runFullDecode(workload);
        }
    }

    private ulong expectedStageChecksum(
        ref const Workload workload,
        StageKind stage)
        @safe pure nothrow @nogc
    {
        final switch (stage)
        {
        case StageKind.groupScan:
            return mix(0, cast(ulong)workload.wayCount);
        case StageKind.semanticPreflight:
            return mix(
                mix(
                    mix(
                        mix(
                            mix(0, cast(ulong)workload.wayCount),
                            cast(ulong)workload.tagCount),
                        cast(ulong)workload.refCount),
                    cast(ulong)workload.locationCount),
                cast(ulong)workload.infoCount);
        case StageKind.prevalidatedEmission:
        case StageKind.fullDecode:
            return workload.refsChecksum;
        }
    }

    private size_t expectedStageTags(
        ref const Workload workload,
        StageKind stage)
        @safe pure nothrow @nogc
    {
        return stage == StageKind.groupScan ? 0 : workload.tagCount;
    }

    private size_t expectedStageRefs(
        ref const Workload workload,
        StageKind stage)
        @safe pure nothrow @nogc
    {
        return stage == StageKind.groupScan ? 0 : workload.refCount;
    }

    private size_t expectedStageLocations(
        ref const Workload workload,
        StageKind stage)
        @safe pure nothrow @nogc
    {
        return stage == StageKind.groupScan ? 0 : workload.locationCount;
    }

    private size_t expectedStageInfo(
        ref const Workload workload,
        StageKind stage)
        @safe pure nothrow @nogc
    {
        return stage == StageKind.groupScan ? 0 : workload.infoCount;
    }

    private bool validateStageRun(
        ref const Workload workload,
        StageKind stage,
        const StageRun run)
        @safe pure nothrow @nogc
    {
        return run.ok &&
            run.wayCount == workload.wayCount &&
            run.tagCount == expectedStageTags(workload, stage) &&
            run.refCount == expectedStageRefs(workload, stage) &&
            run.locationCount == expectedStageLocations(workload, stage) &&
            run.infoCount == expectedStageInfo(workload, stage) &&
            run.checksum == expectedStageChecksum(workload, stage);
    }

    private bool warmupStage(
        ref const Workload workload,
        StageKind stage,
        uint iterations)
        @safe nothrow @nogc
    {
        foreach (_; 0 .. iterations)
        {
            const run = runStage(workload, stage);
            if (!validateStageRun(workload, stage, run))
                return false;
        }
        return true;
    }

    private long timeStage(
        ref const Workload workload,
        StageKind stage,
        uint iterations,
        out ulong observableChecksum)
        @system
    {
        auto stopwatch = StopWatch(AutoStart.yes);
        ulong aggregateChecksum;
        size_t aggregateWays;
        size_t aggregateTags;
        size_t aggregateRefs;
        size_t aggregateLocations;
        size_t aggregateInfo;
        bool ok = true;

        foreach (_; 0 .. iterations)
        {
            const run = runStage(workload, stage);
            aggregateChecksum += run.checksum;
            aggregateWays += run.wayCount;
            aggregateTags += run.tagCount;
            aggregateRefs += run.refCount;
            aggregateLocations += run.locationCount;
            aggregateInfo += run.infoCount;
            ok = ok && run.ok;
        }

        stopwatch.stop();
        observableChecksum = aggregateChecksum;

        const aggregate = StageRun(
            aggregateChecksum,
            aggregateWays,
            aggregateTags,
            aggregateRefs,
            aggregateLocations,
            aggregateInfo,
            ok);
        const expected = StageRun(
            expectedStageChecksum(workload, stage) * iterations,
            workload.wayCount * cast(size_t)iterations,
            expectedStageTags(workload, stage) * cast(size_t)iterations,
            expectedStageRefs(workload, stage) * cast(size_t)iterations,
            expectedStageLocations(workload, stage) * cast(size_t)iterations,
            expectedStageInfo(workload, stage) * cast(size_t)iterations,
            true);
        if (!aggregate.ok ||
            aggregate.checksum != expected.checksum ||
            aggregate.wayCount != expected.wayCount ||
            aggregate.tagCount != expected.tagCount ||
            aggregate.refCount != expected.refCount ||
            aggregate.locationCount != expected.locationCount ||
            aggregate.infoCount != expected.infoCount)
            return -1;

        return stopwatch.peek.total!"nsecs";
    }

    private string stageName(StageKind stage) @safe pure nothrow
    {
        final switch (stage)
        {
        case StageKind.groupScan:
            return "group-scan";
        case StageKind.semanticPreflight:
            return "semantic-preflight";
        case StageKind.prevalidatedEmission:
            return "prevalidated-emission";
        case StageKind.fullDecode:
            return "full-decode";
        }
    }

    private bool parseStage(string name, out StageKind stage)
        @safe pure nothrow
    {
        switch (name)
        {
        case "group-scan":
        case "scan":
            stage = StageKind.groupScan;
            return true;
        case "semantic-preflight":
        case "preflight":
            stage = StageKind.semanticPreflight;
            return true;
        case "prevalidated-emission":
        case "emission":
            stage = StageKind.prevalidatedEmission;
            return true;
        case "full-decode":
        case "full":
            stage = StageKind.fullDecode;
            return true;
        default:
            stage = StageKind.init;
            return false;
        }
    }

    private bool recordStageSample(
        ref const Workload workload,
        StageKind stage,
        uint iterations,
        uint sample,
        long[] scanTimings,
        long[] preflightTimings,
        long[] emissionTimings,
        long[] fullTimings,
        ref ulong scanChecksum,
        ref ulong preflightChecksum,
        ref ulong emissionChecksum,
        ref ulong fullChecksum)
        @system
    {
        ulong observed;
        const elapsed = timeStage(workload, stage, iterations, observed);
        if (elapsed < 0)
            return false;

        final switch (stage)
        {
        case StageKind.groupScan:
            scanTimings[sample] = elapsed;
            scanChecksum += observed ^ cast(ulong)sample;
            break;
        case StageKind.semanticPreflight:
            preflightTimings[sample] = elapsed;
            preflightChecksum += observed ^ cast(ulong)sample;
            break;
        case StageKind.prevalidatedEmission:
            emissionTimings[sample] = elapsed;
            emissionChecksum += observed ^ cast(ulong)sample;
            break;
        case StageKind.fullDecode:
            fullTimings[sample] = elapsed;
            fullChecksum += observed ^ cast(ulong)sample;
            break;
        }
        return true;
    }

    private bool measureAllStages(
        ref const Workload workload,
        uint iterations,
        uint samples,
        uint warmupIterations,
        out BenchResult scan,
        out BenchResult preflight,
        out BenchResult emission,
        out BenchResult full)
        @system
    {
        if (!warmupStage(workload, StageKind.groupScan, warmupIterations) ||
            !warmupStage(workload, StageKind.semanticPreflight, warmupIterations) ||
            !warmupStage(workload, StageKind.prevalidatedEmission, warmupIterations) ||
            !warmupStage(workload, StageKind.fullDecode, warmupIterations))
            return false;

        auto scanTimings = new long[samples];
        auto preflightTimings = new long[samples];
        auto emissionTimings = new long[samples];
        auto fullTimings = new long[samples];
        ulong scanChecksum;
        ulong preflightChecksum;
        ulong emissionChecksum;
        ulong fullChecksum;

        static immutable StageKind[4][24] orders = [
            [StageKind.groupScan, StageKind.semanticPreflight, StageKind.prevalidatedEmission, StageKind.fullDecode],
            [StageKind.groupScan, StageKind.semanticPreflight, StageKind.fullDecode, StageKind.prevalidatedEmission],
            [StageKind.groupScan, StageKind.prevalidatedEmission, StageKind.semanticPreflight, StageKind.fullDecode],
            [StageKind.groupScan, StageKind.prevalidatedEmission, StageKind.fullDecode, StageKind.semanticPreflight],
            [StageKind.groupScan, StageKind.fullDecode, StageKind.semanticPreflight, StageKind.prevalidatedEmission],
            [StageKind.groupScan, StageKind.fullDecode, StageKind.prevalidatedEmission, StageKind.semanticPreflight],
            [StageKind.semanticPreflight, StageKind.groupScan, StageKind.prevalidatedEmission, StageKind.fullDecode],
            [StageKind.semanticPreflight, StageKind.groupScan, StageKind.fullDecode, StageKind.prevalidatedEmission],
            [StageKind.semanticPreflight, StageKind.prevalidatedEmission, StageKind.groupScan, StageKind.fullDecode],
            [StageKind.semanticPreflight, StageKind.prevalidatedEmission, StageKind.fullDecode, StageKind.groupScan],
            [StageKind.semanticPreflight, StageKind.fullDecode, StageKind.groupScan, StageKind.prevalidatedEmission],
            [StageKind.semanticPreflight, StageKind.fullDecode, StageKind.prevalidatedEmission, StageKind.groupScan],
            [StageKind.prevalidatedEmission, StageKind.groupScan, StageKind.semanticPreflight, StageKind.fullDecode],
            [StageKind.prevalidatedEmission, StageKind.groupScan, StageKind.fullDecode, StageKind.semanticPreflight],
            [StageKind.prevalidatedEmission, StageKind.semanticPreflight, StageKind.groupScan, StageKind.fullDecode],
            [StageKind.prevalidatedEmission, StageKind.semanticPreflight, StageKind.fullDecode, StageKind.groupScan],
            [StageKind.prevalidatedEmission, StageKind.fullDecode, StageKind.groupScan, StageKind.semanticPreflight],
            [StageKind.prevalidatedEmission, StageKind.fullDecode, StageKind.semanticPreflight, StageKind.groupScan],
            [StageKind.fullDecode, StageKind.groupScan, StageKind.semanticPreflight, StageKind.prevalidatedEmission],
            [StageKind.fullDecode, StageKind.groupScan, StageKind.prevalidatedEmission, StageKind.semanticPreflight],
            [StageKind.fullDecode, StageKind.semanticPreflight, StageKind.groupScan, StageKind.prevalidatedEmission],
            [StageKind.fullDecode, StageKind.semanticPreflight, StageKind.prevalidatedEmission, StageKind.groupScan],
            [StageKind.fullDecode, StageKind.prevalidatedEmission, StageKind.groupScan, StageKind.semanticPreflight],
            [StageKind.fullDecode, StageKind.prevalidatedEmission, StageKind.semanticPreflight, StageKind.groupScan],
        ];

        foreach (sample; 0 .. samples)
        {
            const order = orders[sample % orders.length];
            foreach (stage; order)
            {
                if (!recordStageSample(
                    workload,
                    stage,
                    iterations,
                    sample,
                    scanTimings,
                    preflightTimings,
                    emissionTimings,
                    fullTimings,
                    scanChecksum,
                    preflightChecksum,
                    emissionChecksum,
                    fullChecksum))
                    return false;
            }
        }

        scan = summarize(scanTimings, scanChecksum);
        preflight = summarize(preflightTimings, preflightChecksum);
        emission = summarize(emissionTimings, emissionChecksum);
        full = summarize(fullTimings, fullChecksum);
        return scan.ok && preflight.ok && emission.ok && full.ok;
    }

    private BenchResult measureSingleStage(
        ref const Workload workload,
        StageKind stage,
        uint iterations,
        uint samples,
        uint warmupIterations)
        @system
    {
        if (!warmupStage(workload, stage, warmupIterations))
            return BenchResult.init;

        auto timings = new long[samples];
        ulong observableChecksum;
        foreach (sample; 0 .. samples)
        {
            ulong observed;
            const elapsed = timeStage(workload, stage, iterations, observed);
            if (elapsed < 0)
                return BenchResult.init;
            timings[sample] = elapsed;
            observableChecksum += observed ^ cast(ulong)sample;
        }
        return summarize(timings, observableChecksum);
    }

    private void reportStage(
        StageKind stage,
        ref const Workload workload,
        uint iterations,
        const BenchResult result)
    {
        const totalWays = cast(double)workload.wayCount * iterations;
        const totalGroupBytes = cast(double)workload.group.raw.length * iterations;
        const medianSeconds = cast(double)result.timings.medianNanoseconds /
            1_000_000_000.0;
        const medianNsPerWay = cast(double)result.timings.medianNanoseconds / totalWays;
        const p10NsPerWay = cast(double)result.timings.p10Nanoseconds / totalWays;
        const p90NsPerWay = cast(double)result.timings.p90Nanoseconds / totalWays;
        const minNsPerWay = cast(double)result.timings.minimumNanoseconds / totalWays;
        const maxNsPerWay = cast(double)result.timings.maximumNanoseconds / totalWays;
        const megaWaysPerSecond = totalWays / medianSeconds / 1_000_000.0;
        const mebiGroupBytesPerSecond =
            totalGroupBytes / medianSeconds / (1024.0 * 1024.0);
        const spreadPercent = result.timings.medianNanoseconds == 0
            ? 0.0
            : cast(double)(
                result.timings.p90Nanoseconds - result.timings.p10Nanoseconds) /
                result.timings.medianNanoseconds * 100.0;

        writefln(
            "%-13s %-21s p50=%8.3f ns/way %7.2f Mway/s %8.2f MiB/s(group)  " ~
            "p10=%8.3f p90=%8.3f Δ80=%5.1f%%  min=%8.3f max=%8.3f  checksum=%016x",
            workload.name,
            stageName(stage),
            medianNsPerWay,
            megaWaysPerSecond,
            mebiGroupBytesPerSecond,
            p10NsPerWay,
            p90NsPerWay,
            spreadPercent,
            minNsPerWay,
            maxNsPerWay,
            result.checksum);
    }

    private void reportDerivedStageCosts(
        ref const Workload workload,
        uint iterations,
        const BenchResult scan,
        const BenchResult preflight,
        const BenchResult emission,
        const BenchResult full)
    {
        const totalWays = cast(double)workload.wayCount * iterations;
        const scanNs = cast(double)scan.timings.medianNanoseconds / totalWays;
        const preflightNs = cast(double)preflight.timings.medianNanoseconds / totalWays;
        const emissionNs = cast(double)emission.timings.medianNanoseconds / totalWays;
        const fullNs = cast(double)full.timings.medianNanoseconds / totalWays;
        const candidateNs = preflightNs + emissionNs;
        const potentialNs = fullNs - candidateNs;
        const potentialPercent = fullNs == 0.0
            ? 0.0
            : potentialNs / fullNs * 100.0;

        writefln(
            "%-13s derived: parse+validate≈%8.3f  current-post≈%8.3f  " ~
            "prevalidated-emission=%8.3f  candidate-total≈%8.3f ns/way  " ~
            "potential≈%+8.3f (%+5.1f%%)",
            workload.name,
            preflightNs - scanNs,
            fullNs - preflightNs,
            emissionNs,
            candidateNs,
            potentialNs,
            potentialPercent);
    }

    private bool runStageWorkload(
        ref const Workload workload,
        bool allStages,
        StageKind selectedStage,
        uint iterations,
        uint samples,
        uint warmupIterations)
        @system
    {
        writefln(
            "profile=%s ways=%s refs=%s refs/way=%.3f tags=%s tags/way=%.3f " ~
            "info-ways=%s locations=%s locations/way=%.3f group-bytes=%s",
            workload.name,
            workload.wayCount,
            workload.refCount,
            workload.wayCount == 0
                ? 0.0
                : cast(double)workload.refCount / workload.wayCount,
            workload.tagCount,
            workload.wayCount == 0
                ? 0.0
                : cast(double)workload.tagCount / workload.wayCount,
            workload.infoCount,
            workload.locationCount,
            workload.wayCount == 0
                ? 0.0
                : cast(double)workload.locationCount / workload.wayCount,
            workload.group.raw.length);

        if (allStages)
        {
            BenchResult scan;
            BenchResult preflight;
            BenchResult emission;
            BenchResult full;
            if (!measureAllStages(
                workload,
                iterations,
                samples,
                warmupIterations,
                scan,
                preflight,
                emission,
                full))
                return false;

            reportStage(StageKind.groupScan, workload, iterations, scan);
            reportStage(StageKind.semanticPreflight, workload, iterations, preflight);
            reportStage(StageKind.prevalidatedEmission, workload, iterations, emission);
            reportStage(StageKind.fullDecode, workload, iterations, full);
            reportDerivedStageCosts(
                workload,
                iterations,
                scan,
                preflight,
                emission,
                full);
            return true;
        }

        const result = measureSingleStage(
            workload,
            selectedStage,
            iterations,
            samples,
            warmupIterations);
        if (!result.ok)
            return false;
        reportStage(selectedStage, workload, iterations, result);
        return true;
    }

    private int runStageMain(string[] args) @system
    {
        size_t wayCount = 20_000;
        uint iterations = 3;
        uint samples = 30;
        uint warmupIterations = 2;
        string selectedProfile = "all";
        string selectedStageName = "all";

        auto options = getopt(
            args,
            "ways", "Regular Ways generated for each workload", &wayCount,
            "iterations", "Complete stage runs per timed sample", &iterations,
            "samples", "Timed samples; robust quantiles are reported", &samples,
            "warmup", "Untimed stage runs before measurement", &warmupIterations,
            "profile", "all|ref-only|typical|typical-info|locations|rich", &selectedProfile,
            "stage", "all|group-scan|semantic-preflight|prevalidated-emission|full-decode", &selectedStageName);

        if (options.helpWanted)
        {
            defaultGetoptPrinter(
                "osm-d regular Way stage benchmark",
                options.options);
            return 0;
        }

        if (wayCount == 0 || iterations == 0 || samples == 0)
        {
            stderr.writeln("ways, iterations and samples must all be greater than zero");
            return 2;
        }
        if (samples > 100_000)
        {
            stderr.writeln("samples is unreasonably large");
            return 2;
        }

        const allStages = selectedStageName == "all";
        StageKind selectedStage;
        if (!allStages && !parseStage(selectedStageName, selectedStage))
        {
            stderr.writefln("unknown stage: %s", selectedStageName);
            return 2;
        }

        writeln("osm-d regular Way stage benchmark");
        writefln("compiler: %s (%s)", __VENDOR__, __VERSION__);
        writefln(
            "ways/profile: %s  iterations/sample: %s  samples: %s  warmup: %s",
            wayCount,
            iterations,
            samples,
            warmupIterations);
        if (allStages)
            writeln("ordering: rotating all 24 permutations of the four stages");
        else
            writefln("ordering: single stage (%s)", selectedStageName);
        writeln("statistics: min, p10, p50, p90, max; Δ80=(p90-p10)/p50");
        writeln("group-scan: benchmark-local mirror of private WayMessageCursor traversal");
        writeln("semantic-preflight: benchmark-local mirror of the current private first parse/validation pass");
        writeln("prevalidated-emission: benchmark-local second pass that rebuilds borrowed ranges while skipping duplicate tag/ref/location semantic validation");
        writeln("full-decode: production decodeWays with the refs sink");
        writeln("derived values subtract medians and are diagnostic, not independently timed stages");
        writeln("excluded: workload generation, block/group layout, StringTable indexing, sorting and reporting");
        writeln();

        static immutable WorkloadProfile[5] allProfiles = [
            WorkloadProfile.refOnly,
            WorkloadProfile.typical,
            WorkloadProfile.typicalInfo,
            WorkloadProfile.locations,
            WorkloadProfile.rich,
        ];

        if (selectedProfile == "all")
        {
            foreach (profile; allProfiles)
            {
                Workload workload;
                if (!buildWorkload(profile, wayCount, workload))
                {
                    stderr.writefln(
                        "failed to build/validate profile: %s",
                        profileName(profile));
                    return 3;
                }
                if (!runStageWorkload(
                    workload,
                    allStages,
                    selectedStage,
                    iterations,
                    samples,
                    warmupIterations))
                {
                    stderr.writefln(
                        "stage benchmark consistency failure: %s",
                        workload.name);
                    return 3;
                }
                writeln();
            }
            return 0;
        }

        WorkloadProfile profile;
        if (!parseProfile(selectedProfile, profile))
        {
            stderr.writefln("unknown profile: %s", selectedProfile);
            return 2;
        }

        Workload workload;
        if (!buildWorkload(profile, wayCount, workload))
        {
            stderr.writefln(
                "failed to build/validate profile: %s",
                selectedProfile);
            return 3;
        }
        if (!runStageWorkload(
            workload,
            allStages,
            selectedStage,
            iterations,
            samples,
            warmupIterations))
        {
            stderr.writefln(
                "stage benchmark consistency failure: %s",
                workload.name);
            return 3;
        }
        return 0;
    }
}

version (RegularWayStageBenchmark)
{
    int main(string[] args) @system
    {
        return runStageMain(args);
    }
}
else
{
    int main(string[] args) @system
    {
        return runRegularMain(args);
    }
}
