/**
 * Microbenchmark for the production OSMPBF regular Node decode path.
 *
 * The benchmark measures the public `decodeNodes` path on deterministic
 * synthetic PrimitiveBlocks. PrimitiveBlock/PrimitiveGroup layout discovery,
 * StringTable indexing, workload generation, correctness validation, sample
 * ordering, sorting and reporting remain outside the timed region. Timed work
 * includes the complete regular-Node semantic preflight, the second production
 * parse/emission pass, TagRange construction and one of three observable sinks.
 *
 * This is an in-memory CPU/cache microbenchmark. It does not include file I/O,
 * Blob framing, decompression, HeaderBlock processing or owned-model/store
 * construction and must not be quoted as end-to-end PBF parser throughput.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-13
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module benchmark.micro.regular_nodes;

import osm.io.pbf.error : PbfStatus;
import osm.io.pbf.info : InfoView;
import osm.io.pbf.node :
    NodeDecodeSummary,
    NodeView,
    decodeNodes;
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

import std.algorithm.sorting : sort;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, writefln, writeln;

private enum WorkloadProfile
{
    tagless,
    typical,
    typicalInfo,
    rich,
}

private enum SinkPath
{
    coordinates,
    tagIds,
    tagBytes,
}

private struct DecodeRun
{
    ulong checksum;
    size_t nodeCount;
    size_t tagCount;
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
    size_t nodeCount;
    size_t tagCount;
    size_t infoCount;
    ulong coordinateChecksum;
    ulong tagIdChecksum;
    ulong tagByteChecksum;
}

private struct CoordinateSink
{
    ulong checksum;
    size_t nodeCount;
    size_t infoCount;

    void put(scope ref NodeView node) @safe nothrow @nogc
    {
        checksum = mix(checksum, cast(ulong)node.id);
        checksum = mix(checksum, cast(ulong)node.latNano);
        checksum = mix(checksum, cast(ulong)node.lonNano);
        consumeInfo(checksum, infoCount, node.info);
        ++nodeCount;
    }
}

private struct TagIdSink
{
    ulong checksum;
    size_t nodeCount;
    size_t tagCount;
    size_t infoCount;

    void put(scope ref NodeView node) @safe nothrow @nogc
    {
        checksum = mix(checksum, cast(ulong)node.id);
        checksum = mix(checksum, cast(ulong)node.latNano);
        checksum = mix(checksum, cast(ulong)node.lonNano);
        consumeInfo(checksum, infoCount, node.info);

        auto tags = node.tags;
        while (!tags.empty)
        {
            const tag = tags.front;
            checksum = mix(checksum, tag.keySid);
            checksum = mix(checksum, tag.valueSid);
            ++tagCount;
            tags.popFront();
        }

        ++nodeCount;
    }
}

private struct TagByteSink
{
    ulong checksum;
    size_t nodeCount;
    size_t tagCount;
    size_t infoCount;

    void put(scope ref NodeView node) @safe nothrow @nogc
    {
        checksum = mix(checksum, cast(ulong)node.id);
        checksum = mix(checksum, cast(ulong)node.latNano);
        checksum = mix(checksum, cast(ulong)node.lonNano);
        consumeInfo(checksum, infoCount, node.info);

        auto tags = node.tags;
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

        ++nodeCount;
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

private DecodeRun decodeCoordinates(ref const Workload workload)
    @safe nothrow @nogc
{
    CoordinateSink sink;
    NodeDecodeSummary summary;
    PbfStatus status;
    const ok = decodeNodes(
        workload.block,
        workload.group,
        workload.table,
        sink,
        summary,
        status);

    return DecodeRun(
        sink.checksum,
        summary.nodeCount,
        summary.tagCount,
        sink.infoCount,
        ok && sink.nodeCount == summary.nodeCount);
}

private DecodeRun decodeTagIds(ref const Workload workload)
    @safe nothrow @nogc
{
    TagIdSink sink;
    NodeDecodeSummary summary;
    PbfStatus status;
    const ok = decodeNodes(
        workload.block,
        workload.group,
        workload.table,
        sink,
        summary,
        status);

    return DecodeRun(
        sink.checksum,
        summary.nodeCount,
        summary.tagCount,
        sink.infoCount,
        ok && sink.nodeCount == summary.nodeCount &&
            sink.tagCount == summary.tagCount);
}

private DecodeRun decodeTagBytes(ref const Workload workload)
    @safe nothrow @nogc
{
    TagByteSink sink;
    NodeDecodeSummary summary;
    PbfStatus status;
    const ok = decodeNodes(
        workload.block,
        workload.group,
        workload.table,
        sink,
        summary,
        status);

    return DecodeRun(
        sink.checksum,
        summary.nodeCount,
        summary.tagCount,
        sink.infoCount,
        ok && sink.nodeCount == summary.nodeCount &&
            sink.tagCount == summary.tagCount);
}

private ulong expectedChecksum(ref const Workload workload, SinkPath path)
    @safe pure nothrow @nogc
{
    final switch (path)
    {
    case SinkPath.coordinates:
        return workload.coordinateChecksum;
    case SinkPath.tagIds:
        return workload.tagIdChecksum;
    case SinkPath.tagBytes:
        return workload.tagByteChecksum;
    }
}

private DecodeRun decodeSelected(ref const Workload workload, SinkPath path)
    @safe nothrow @nogc
{
    final switch (path)
    {
    case SinkPath.coordinates:
        return decodeCoordinates(workload);
    case SinkPath.tagIds:
        return decodeTagIds(workload);
    case SinkPath.tagBytes:
        return decodeTagBytes(workload);
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
        aggregate.nodeCount == workload.nodeCount * cast(size_t)iterations &&
        aggregate.tagCount == workload.tagCount * cast(size_t)iterations &&
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
            run.nodeCount != workload.nodeCount ||
            run.tagCount != workload.tagCount ||
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
    size_t aggregateNodes;
    size_t aggregateTags;
    size_t aggregateInfo;
    bool ok = true;

    foreach (_; 0 .. iterations)
    {
        const run = decodeSelected(workload, path);
        aggregateChecksum += run.checksum;
        aggregateNodes += run.nodeCount;
        aggregateTags += run.tagCount;
        aggregateInfo += run.infoCount;
        ok = ok && run.ok;
    }

    stopwatch.stop();
    observableChecksum = aggregateChecksum;

    const aggregate = DecodeRun(
        aggregateChecksum,
        aggregateNodes,
        aggregateTags,
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

private bool recordSample(
    ref const Workload workload,
    SinkPath path,
    uint iterations,
    uint sample,
    long[] coordinateTimings,
    long[] tagIdTimings,
    long[] tagByteTimings,
    ref ulong coordinateChecksum,
    ref ulong tagIdChecksum,
    ref ulong tagByteChecksum)
    @system
{
    ulong observed;
    const elapsed = timePath(workload, path, iterations, observed);
    if (elapsed < 0)
        return false;

    final switch (path)
    {
    case SinkPath.coordinates:
        coordinateTimings[sample] = elapsed;
        coordinateChecksum += observed ^ cast(ulong)sample;
        break;
    case SinkPath.tagIds:
        tagIdTimings[sample] = elapsed;
        tagIdChecksum += observed ^ cast(ulong)sample;
        break;
    case SinkPath.tagBytes:
        tagByteTimings[sample] = elapsed;
        tagByteChecksum += observed ^ cast(ulong)sample;
        break;
    }
    return true;
}

private bool measureAll(
    ref const Workload workload,
    uint iterations,
    uint samples,
    uint warmupIterations,
    out BenchResult coordinates,
    out BenchResult tagIds,
    out BenchResult tagBytes)
    @system
{
    if (!warmup(workload, SinkPath.coordinates, warmupIterations) ||
        !warmup(workload, SinkPath.tagIds, warmupIterations) ||
        !warmup(workload, SinkPath.tagBytes, warmupIterations))
        return false;

    auto coordinateTimings = new long[samples];
    auto tagIdTimings = new long[samples];
    auto tagByteTimings = new long[samples];
    ulong coordinateChecksum;
    ulong tagIdChecksum;
    ulong tagByteChecksum;

    static immutable SinkPath[3][6] orders = [
        [SinkPath.coordinates, SinkPath.tagIds, SinkPath.tagBytes],
        [SinkPath.coordinates, SinkPath.tagBytes, SinkPath.tagIds],
        [SinkPath.tagIds, SinkPath.coordinates, SinkPath.tagBytes],
        [SinkPath.tagIds, SinkPath.tagBytes, SinkPath.coordinates],
        [SinkPath.tagBytes, SinkPath.coordinates, SinkPath.tagIds],
        [SinkPath.tagBytes, SinkPath.tagIds, SinkPath.coordinates],
    ];

    foreach (sample; 0 .. samples)
    {
        const order = orders[sample % orders.length];
        foreach (path; order)
        {
            if (!recordSample(
                workload,
                path,
                iterations,
                sample,
                coordinateTimings,
                tagIdTimings,
                tagByteTimings,
                coordinateChecksum,
                tagIdChecksum,
                tagByteChecksum))
                return false;
        }
    }

    coordinates = summarize(coordinateTimings, coordinateChecksum);
    tagIds = summarize(tagIdTimings, tagIdChecksum);
    tagBytes = summarize(tagByteTimings, tagByteChecksum);
    return coordinates.ok && tagIds.ok && tagBytes.ok;
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
    case SinkPath.coordinates:
        return "coordinates";
    case SinkPath.tagIds:
        return "tag-ids";
    case SinkPath.tagBytes:
        return "tag-bytes";
    }
}

private void report(
    SinkPath path,
    ref const Workload workload,
    uint iterations,
    const BenchResult result)
{
    const totalNodes = cast(double)workload.nodeCount * iterations;
    const totalGroupBytes = cast(double)workload.group.raw.length * iterations;
    const medianSeconds = cast(double)result.timings.medianNanoseconds /
        1_000_000_000.0;
    const medianNsPerNode = cast(double)result.timings.medianNanoseconds / totalNodes;
    const p10NsPerNode = cast(double)result.timings.p10Nanoseconds / totalNodes;
    const p90NsPerNode = cast(double)result.timings.p90Nanoseconds / totalNodes;
    const minNsPerNode = cast(double)result.timings.minimumNanoseconds / totalNodes;
    const maxNsPerNode = cast(double)result.timings.maximumNanoseconds / totalNodes;
    const megaNodesPerSecond = totalNodes / medianSeconds / 1_000_000.0;
    const mebiGroupBytesPerSecond = totalGroupBytes / medianSeconds / (1024.0 * 1024.0);
    const spreadPercent = result.timings.medianNanoseconds == 0
        ? 0.0
        : cast(double)(result.timings.p90Nanoseconds - result.timings.p10Nanoseconds) /
            result.timings.medianNanoseconds * 100.0;

    writefln(
        "%-12s %-12s p50=%8.3f ns/node %7.2f Mnode/s %8.2f MiB/s(group)  " ~
        "p10=%8.3f p90=%8.3f Δ80=%5.1f%%  min=%8.3f max=%8.3f  checksum=%016x",
        workload.name,
        pathName(path),
        medianNsPerNode,
        megaNodesPerSecond,
        mebiGroupBytesPerSecond,
        p10NsPerNode,
        p90NsPerNode,
        spreadPercent,
        minNsPerNode,
        maxNsPerNode,
        result.checksum);
}

private bool parseProfile(string name, out WorkloadProfile profile)
    @safe pure nothrow
{
    switch (name)
    {
    case "tagless": profile = WorkloadProfile.tagless; return true;
    case "typical": profile = WorkloadProfile.typical; return true;
    case "typical-info": profile = WorkloadProfile.typicalInfo; return true;
    case "rich": profile = WorkloadProfile.rich; return true;
    default: profile = WorkloadProfile.init; return false;
    }
}

private bool parsePath(string name, out SinkPath path)
    @safe pure nothrow
{
    switch (name)
    {
    case "coordinates":
    case "coords":
        path = SinkPath.coordinates;
        return true;
    case "tag-ids":
    case "tags":
        path = SinkPath.tagIds;
        return true;
    case "tag-bytes":
    case "strings":
        path = SinkPath.tagBytes;
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
    case WorkloadProfile.tagless: return "tagless";
    case WorkloadProfile.typical: return "typical";
    case WorkloadProfile.typicalInfo: return "typical-info";
    case WorkloadProfile.rich: return "rich";
    }
}

private size_t tagCountForNode(WorkloadProfile profile)
    @safe pure nothrow @nogc
{
    final switch (profile)
    {
    case WorkloadProfile.tagless:
        return 0;
    case WorkloadProfile.typical:
    case WorkloadProfile.typicalInfo:
        return 2;
    case WorkloadProfile.rich:
        return 8;
    }
}

private bool hasInfo(WorkloadProfile profile) @safe pure nothrow @nogc
{
    return profile == WorkloadProfile.typicalInfo ||
        profile == WorkloadProfile.rich;
}

private long nodeId(size_t nodeIndex) @safe pure nothrow @nogc
{
    return 1_000_000_000L + cast(long)nodeIndex;
}

private long latitudeValue(size_t nodeIndex) @safe pure nothrow @nogc
{
    return 480_000_000L + cast(long)(nodeIndex & 1023) - 512;
}

private long longitudeValue(size_t nodeIndex) @safe pure nothrow @nogc
{
    return 160_000_000L + cast(long)((nodeIndex * 3) & 1023) - 512;
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

private void appendInfo(ref ubyte[] info, size_t nodeIndex)
{
    appendFieldKey(info, 1, 0);
    appendVarint(info, 1 + (nodeIndex & 7));

    appendFieldKey(info, 2, 0);
    appendVarint(info, 1_700_000_000UL + (nodeIndex % 86_400));

    appendFieldKey(info, 3, 0);
    appendVarint(info, 10_000_000UL + nodeIndex);

    appendFieldKey(info, 4, 0);
    appendVarint(info, 1_000 + (nodeIndex & 1023));

    appendFieldKey(info, 5, 0);
    appendVarint(info, 17);

    appendFieldKey(info, 6, 0);
    appendVarint(info, 1);
}

private bool buildWorkload(
    WorkloadProfile profile,
    size_t nodeCount,
    out Workload workload)
    @system
{
    workload = Workload.init;
    workload.name = profileName(profile);
    workload.nodeCount = nodeCount;

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
    ubyte[] node;
    ubyte[] keys;
    ubyte[] vals;
    ubyte[] info;
    size_t totalTags;
    size_t totalInfo;

    foreach (i; 0 .. nodeCount)
    {
        node.length = 0;
        keys.length = 0;
        vals.length = 0;
        info.length = 0;

        appendFieldKey(node, 1, 0);
        appendVarint(node, zigZag64(nodeId(i)));

        const tags = tagCountForNode(profile);
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
            appendLengthDelimited(node, 2, keys);
            appendLengthDelimited(node, 3, vals);
        }

        if (hasInfo(profile))
        {
            appendInfo(info, i);
            appendLengthDelimited(node, 4, info);
            ++totalInfo;
        }

        appendFieldKey(node, 8, 0);
        appendVarint(node, zigZag64(latitudeValue(i)));

        appendFieldKey(node, 9, 0);
        appendVarint(node, zigZag64(longitudeValue(i)));

        appendLengthDelimited(group, 1, node);
    }

    workload.tagCount = totalTags;
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

    if (workload.group.nodeOccurrences != nodeCount)
        return false;

    const coordinates = decodeCoordinates(workload);
    const tagIds = decodeTagIds(workload);
    const tagBytes = decodeTagBytes(workload);
    if (!coordinates.ok || !tagIds.ok || !tagBytes.ok ||
        coordinates.nodeCount != nodeCount ||
        coordinates.tagCount != totalTags ||
        coordinates.infoCount != totalInfo ||
        tagIds.nodeCount != nodeCount ||
        tagIds.tagCount != totalTags ||
        tagIds.infoCount != totalInfo ||
        tagBytes.nodeCount != nodeCount ||
        tagBytes.tagCount != totalTags ||
        tagBytes.infoCount != totalInfo)
        return false;

    workload.coordinateChecksum = coordinates.checksum;
    workload.tagIdChecksum = tagIds.checksum;
    workload.tagByteChecksum = tagBytes.checksum;
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
        "profile=%s nodes=%s tags=%s tags/node=%.3f info-nodes=%s group-bytes=%s",
        workload.name,
        workload.nodeCount,
        workload.tagCount,
        workload.nodeCount == 0
            ? 0.0
            : cast(double)workload.tagCount / workload.nodeCount,
        workload.infoCount,
        workload.group.raw.length);

    if (allPaths)
    {
        BenchResult coordinates;
        BenchResult tagIds;
        BenchResult tagBytes;
        if (!measureAll(
            workload,
            iterations,
            samples,
            warmupIterations,
            coordinates,
            tagIds,
            tagBytes))
            return false;

        report(SinkPath.coordinates, workload, iterations, coordinates);
        report(SinkPath.tagIds, workload, iterations, tagIds);
        report(SinkPath.tagBytes, workload, iterations, tagBytes);
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

/**
 * Run the regular-Node microbenchmark.
 *
 * Command-line options:
 *
 * - `--nodes`: regular Nodes generated per workload;
 * - `--iterations`: complete group decodes per timed sample;
 * - `--samples`: timed samples;
 * - `--warmup`: untimed decodes before measurement;
 * - `--profile`: `all`, `tagless`, `typical`, `typical-info`, or `rich`;
 * - `--path`: `all`, `coordinates`, `tag-ids`, or `tag-bytes`.
 *
 * Returns:
 *   Zero on success, non-zero for invalid arguments or consistency failure.
 */
int main(string[] args) @system
{
    size_t nodeCount = 100_000;
    uint iterations = 3;
    uint samples = 30;
    uint warmupIterations = 2;
    string selectedProfile = "all";
    string selectedPathName = "all";

    auto options = getopt(
        args,
        "nodes", "Regular Nodes generated for each workload", &nodeCount,
        "iterations", "Complete regular-Node decodes per timed sample", &iterations,
        "samples", "Timed samples; robust quantiles are reported", &samples,
        "warmup", "Untimed decodes before measurement", &warmupIterations,
        "profile", "all|tagless|typical|typical-info|rich", &selectedProfile,
        "path", "all|coordinates|tag-ids|tag-bytes", &selectedPathName);

    if (options.helpWanted)
    {
        defaultGetoptPrinter(
            "d-osm regular Node microbenchmark",
            options.options);
        return 0;
    }

    if (nodeCount == 0 || iterations == 0 || samples == 0)
    {
        stderr.writeln("nodes, iterations and samples must all be greater than zero");
        return 2;
    }
    if (samples > 100_000)
    {
        stderr.writeln("samples is unreasonably large");
        return 2;
    }

    bool allPaths = selectedPathName == "all";
    SinkPath selectedPath;
    if (!allPaths && !parsePath(selectedPathName, selectedPath))
    {
        stderr.writefln("unknown path: %s", selectedPathName);
        return 2;
    }

    writeln("d-osm regular Node microbenchmark");
    writefln("compiler: %s (%s)", __VENDOR__, __VERSION__);
    writefln(
        "nodes/profile: %s  iterations/sample: %s  samples: %s  warmup: %s",
        nodeCount,
        iterations,
        samples,
        warmupIterations);
    if (allPaths)
        writeln("ordering: rotating all six permutations of the three sink paths");
    else
        writefln("ordering: single path (%s)", selectedPathName);
    writeln("statistics: min, p10, p50, p90, max; Δ80=(p90-p10)/p50");
    writeln("timed: production decodeNodes full preflight + second parse/emission + selected sink work");
    writeln("excluded: workload generation, block/group layout, StringTable indexing, validation, sorting and reporting");
    writeln("MiB/s(group) is serialized PrimitiveGroup memory throughput, not compressed PBF I/O");
    writeln();

    static immutable WorkloadProfile[4] allProfiles = [
        WorkloadProfile.tagless,
        WorkloadProfile.typical,
        WorkloadProfile.typicalInfo,
        WorkloadProfile.rich,
    ];

    if (selectedProfile == "all")
    {
        foreach (profile; allProfiles)
        {
            Workload workload;
            if (!buildWorkload(profile, nodeCount, workload))
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
    if (!buildWorkload(profile, nodeCount, workload))
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
