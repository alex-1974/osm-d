/**
 * Microbenchmark for the production OSMPBF DenseNodes decode hot path.
 *
 * The benchmark measures the public `decodeDenseNodes` path on deterministic
 * synthetic PrimitiveBlocks. PrimitiveBlock/PrimitiveGroup layout discovery,
 * StringTable indexing, workload generation, validation, sample ordering,
 * sorting and reporting remain outside the timed region. Timed work includes
 * DenseNodes coordinate/tag preflight and node emission through one of three
 * statically dispatched sinks.
 *
 * This is an in-memory CPU/cache microbenchmark. It does not include file I/O,
 * Blob framing, decompression, HeaderBlock processing or owned-model/store
 * construction and must not be quoted as end-to-end PBF parser throughput.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module benchmark.micro.dense_nodes;

import osm.io.pbf.dense_nodes :
    DenseNodeDecodeSummary,
    DenseNodeView,
    decodeDenseNodes;
import osm.io.pbf.error : PbfStatus;
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
    rich,
    mixed,
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
    ulong coordinateChecksum;
    ulong tagIdChecksum;
    ulong tagByteChecksum;
}

private struct CoordinateSink
{
    ulong checksum;
    size_t nodeCount;

    void put(DenseNodeView node) @safe nothrow @nogc
    {
        checksum = mix(checksum, cast(ulong)node.id);
        checksum = mix(checksum, cast(ulong)node.latNano);
        checksum = mix(checksum, cast(ulong)node.lonNano);
        ++nodeCount;
    }
}

private struct TagIdSink
{
    ulong checksum;
    size_t nodeCount;
    size_t tagCount;

    void put(DenseNodeView node) @safe nothrow @nogc
    {
        checksum = mix(checksum, cast(ulong)node.id);
        checksum = mix(checksum, cast(ulong)node.latNano);
        checksum = mix(checksum, cast(ulong)node.lonNano);

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

    void put(DenseNodeView node) @safe nothrow @nogc
    {
        checksum = mix(checksum, cast(ulong)node.id);
        checksum = mix(checksum, cast(ulong)node.latNano);
        checksum = mix(checksum, cast(ulong)node.lonNano);

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

private DecodeRun decodeCoordinates(ref const Workload workload)
    @safe nothrow @nogc
{
    CoordinateSink sink;
    DenseNodeDecodeSummary summary;
    PbfStatus status;
    const ok = decodeDenseNodes(
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
        ok && sink.nodeCount == summary.nodeCount);
}

private DecodeRun decodeTagIds(ref const Workload workload)
    @safe nothrow @nogc
{
    TagIdSink sink;
    DenseNodeDecodeSummary summary;
    PbfStatus status;
    const ok = decodeDenseNodes(
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
        ok && sink.nodeCount == summary.nodeCount &&
            sink.tagCount == summary.tagCount);
}

private DecodeRun decodeTagBytes(ref const Workload workload)
    @safe nothrow @nogc
{
    TagByteSink sink;
    DenseNodeDecodeSummary summary;
    PbfStatus status;
    const ok = decodeDenseNodes(
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
    bool ok = true;

    foreach (_; 0 .. iterations)
    {
        const run = decodeSelected(workload, path);
        aggregateChecksum += run.checksum;
        aggregateNodes += run.nodeCount;
        aggregateTags += run.tagCount;
        ok = ok && run.ok;
    }

    stopwatch.stop();
    observableChecksum = aggregateChecksum;

    const aggregate = DecodeRun(
        aggregateChecksum,
        aggregateNodes,
        aggregateTags,
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
        "%-9s %-12s p50=%8.3f ns/node %7.2f Mnode/s %8.2f MiB/s(group)  " ~
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
    case "rich": profile = WorkloadProfile.rich; return true;
    case "mixed": profile = WorkloadProfile.mixed; return true;
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
    case WorkloadProfile.rich: return "rich";
    case WorkloadProfile.mixed: return "mixed";
    }
}

private size_t tagCountForNode(WorkloadProfile profile, size_t nodeIndex)
    @safe pure nothrow @nogc
{
    final switch (profile)
    {
    case WorkloadProfile.tagless:
        return 0;
    case WorkloadProfile.typical:
        return 2;
    case WorkloadProfile.rich:
        return 8;
    case WorkloadProfile.mixed:
        switch (nodeIndex & 7)
        {
        case 0: return 0;
        case 1: return 1;
        case 2: return 2;
        case 3: return 3;
        case 4: return 0;
        case 5: return 2;
        case 6: return 4;
        case 7: return 1;
        default: assert(0);
        }
    }
}

private long latitudeDelta(size_t nodeIndex) @safe pure nothrow @nogc
{
    switch (nodeIndex & 7)
    {
    case 0: return 1;
    case 1: return 0;
    case 2: return -1;
    case 3: return 2;
    case 4: return -2;
    case 5: return 1;
    case 6: return 0;
    case 7: return 1;
    default: assert(0);
    }
}

private long longitudeDelta(size_t nodeIndex) @safe pure nothrow @nogc
{
    switch (nodeIndex & 7)
    {
    case 0: return -1;
    case 1: return 1;
    case 2: return 0;
    case 3: return 1;
    case 4: return 2;
    case 5: return -1;
    case 6: return -2;
    case 7: return 0;
    default: assert(0);
    }
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

private bool buildWorkload(
    WorkloadProfile profile,
    size_t nodeCount,
    out Workload workload)
    @system
{
    workload = Workload.init;
    workload.name = profileName(profile);
    workload.nodeCount = nodeCount;

    static immutable string[17] strings = [
        "",
        "highway", "residential",
        "name", "Main Street",
        "surface", "asphalt",
        "lit", "yes",
        "maxspeed", "50",
        "lanes", "2",
        "access", "destination",
        "source", "survey",
    ];

    ubyte[] stringTable;
    foreach (value; strings)
        appendString(stringTable, value);

    ubyte[] ids;
    ubyte[] lats;
    ubyte[] lons;
    ubyte[] keysVals;
    size_t totalTags;

    foreach (i; 0 .. nodeCount)
    {
        appendVarint(ids, zigZag64(1));
        appendVarint(lats, zigZag64(latitudeDelta(i)));
        appendVarint(lons, zigZag64(longitudeDelta(i)));

        const tags = tagCountForNode(profile, i);
        totalTags += tags;
        if (profile != WorkloadProfile.tagless)
        {
            foreach (tagIndex; 0 .. tags)
            {
                const pair = (i + tagIndex) & 7;
                const keySid = 1 + pair * 2;
                const valueSid = keySid + 1;
                appendVarint(keysVals, keySid);
                appendVarint(keysVals, valueSid);
            }
            appendVarint(keysVals, 0);
        }
    }
    workload.tagCount = totalTags;

    ubyte[] dense;
    appendLengthDelimited(dense, 1, ids);
    appendLengthDelimited(dense, 8, lats);
    appendLengthDelimited(dense, 9, lons);
    if (profile != WorkloadProfile.tagless)
        appendLengthDelimited(dense, 10, keysVals);

    ubyte[] group;
    appendLengthDelimited(group, 2, dense);

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

    if (workload.group.dense.nodeCount != nodeCount)
        return false;

    const coordinates = decodeCoordinates(workload);
    const tagIds = decodeTagIds(workload);
    const tagBytes = decodeTagBytes(workload);
    if (!coordinates.ok || !tagIds.ok || !tagBytes.ok ||
        coordinates.nodeCount != nodeCount ||
        coordinates.tagCount != totalTags ||
        tagIds.nodeCount != nodeCount ||
        tagIds.tagCount != totalTags ||
        tagBytes.nodeCount != nodeCount ||
        tagBytes.tagCount != totalTags)
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
        "profile=%s nodes=%s tags=%s tags/node=%.3f group-bytes=%s",
        workload.name,
        workload.nodeCount,
        workload.tagCount,
        workload.nodeCount == 0
            ? 0.0
            : cast(double)workload.tagCount / workload.nodeCount,
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
 * Run the DenseNodes microbenchmark.
 *
 * Command-line options:
 *
 * - `--nodes`: dense nodes generated per workload;
 * - `--iterations`: complete DenseNodes decodes per timed sample;
 * - `--samples`: timed samples;
 * - `--warmup`: untimed decodes before measurement;
 * - `--profile`: `all`, `tagless`, `typical`, `rich`, or `mixed`;
 * - `--path`: `all`, `coordinates`, `tag-ids`, or `tag-bytes`.
 *
 * Returns:
 *   Zero on success, non-zero for invalid arguments or consistency failure.
 */
int main(string[] args) @system
{
    size_t nodeCount = 200_000;
    uint iterations = 5;
    uint samples = 30;
    uint warmupIterations = 2;
    string selectedProfile = "all";
    string selectedPathName = "all";

    auto options = getopt(
        args,
        "nodes", "Dense nodes generated for each workload", &nodeCount,
        "iterations", "Complete DenseNodes decodes per timed sample", &iterations,
        "samples", "Timed samples; robust quantiles are reported", &samples,
        "warmup", "Untimed decodes before measurement", &warmupIterations,
        "profile", "all|tagless|typical|rich|mixed", &selectedProfile,
        "path", "all|coordinates|tag-ids|tag-bytes", &selectedPathName);

    if (options.helpWanted)
    {
        defaultGetoptPrinter(
            "d-osm DenseNodes microbenchmark",
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

    writeln("d-osm DenseNodes microbenchmark");
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
    writeln("timed: production decodeDenseNodes preflight + emission + selected sink work");
    writeln("excluded: workload generation, block/group layout, StringTable indexing, validation, sorting and reporting");
    writeln("MiB/s(group) is serialized PrimitiveGroup memory throughput, not compressed PBF I/O");
    writeln();

    static immutable WorkloadProfile[4] allProfiles = [
        WorkloadProfile.tagless,
        WorkloadProfile.typical,
        WorkloadProfile.rich,
        WorkloadProfile.mixed,
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
