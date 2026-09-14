/**
 * Diagnostic microbenchmark for the DenseNodes coordinate decode core.
 *
 * The benchmark removes PrimitiveGroup scanning, tags, DenseInfo and node-view
 * construction. Separate encoded sint64 delta streams for ID, latitude and
 * longitude are generated with the same deterministic delta patterns as the
 * DenseNodes benchmark. Five stages read the same three input streams and
 * isolate sint64 decoding (varint plus ZigZag), unchecked versus checked delta
 * accumulation, and unchecked versus checked exact nanodegree conversion.
 * Each checked/unchecked
 * pair produces the same observable checksum. A matching C++ reference lives in
 * `reference/dense_coordinate_stages_cpp.cpp`.
 *
 * This is a diagnostic benchmark, not an end-to-end parser benchmark.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module benchmark.micro.dense_coordinate_stages;

import osm.util.checked : checkedAdd, checkedMulAdd;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.varint : readSVarint64;

import std.algorithm.sorting : sort;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, writefln, writeln;

private enum Stage
{
    sint64Decode,
    deltaUnchecked,
    deltaChecked,
    coordinatesUnchecked,
    coordinatesChecked,
}

private struct Workload
{
    ubyte[] ids;
    ubyte[] lats;
    ubyte[] lons;
    size_t nodeCount;
    int granularity;
    long latOffset;
    long lonOffset;
}

private struct StageRun
{
    ulong checksum;
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

pragma(inline, true)
private ulong mix(ulong state, ulong value) @safe pure nothrow @nogc
{
    return state ^ (value + 0x9e37_79b9_7f4a_7c15UL + (state << 6) + (state >> 2));
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

private Workload buildWorkload(size_t nodeCount)
{
    Workload result;
    result.nodeCount = nodeCount;
    result.granularity = 100;
    result.latOffset = 0;
    result.lonOffset = 0;

    foreach (i; 0 .. nodeCount)
    {
        appendVarint(result.ids, zigZag64(1));
        appendVarint(result.lats, zigZag64(latitudeDelta(i)));
        appendVarint(result.lons, zigZag64(longitudeDelta(i)));
    }
    return result;
}

pragma(inline, true)
private bool readTriple(
    ref WireCursor ids,
    ref WireCursor lats,
    ref WireCursor lons,
    out long id,
    out long lat,
    out long lon)
    @safe nothrow @nogc
{
    WireStatus status;
    return readSVarint64(ids, id, status) &&
        readSVarint64(lats, lat, status) &&
        readSVarint64(lons, lon, status);
}

private StageRun runSint64Decode(ref const Workload workload)
    @safe nothrow @nogc
{
    auto ids = WireCursor(workload.ids);
    auto lats = WireCursor(workload.lats);
    auto lons = WireCursor(workload.lons);
    ulong checksum;

    foreach (_; 0 .. workload.nodeCount)
    {
        long idDelta;
        long latDelta;
        long lonDelta;
        if (!readTriple(ids, lats, lons, idDelta, latDelta, lonDelta))
            return StageRun(0, false);
        checksum = mix(checksum, cast(ulong)idDelta);
        checksum = mix(checksum, cast(ulong)latDelta);
        checksum = mix(checksum, cast(ulong)lonDelta);
    }

    return StageRun(checksum, ids.empty && lats.empty && lons.empty);
}

private StageRun runDeltaUnchecked(ref const Workload workload)
    @safe nothrow @nogc
{
    auto ids = WireCursor(workload.ids);
    auto lats = WireCursor(workload.lats);
    auto lons = WireCursor(workload.lons);
    long id;
    long lat;
    long lon;
    ulong checksum;

    foreach (_; 0 .. workload.nodeCount)
    {
        long idDelta;
        long latDelta;
        long lonDelta;
        if (!readTriple(ids, lats, lons, idDelta, latDelta, lonDelta))
            return StageRun(0, false);

        id += idDelta;
        lat += latDelta;
        lon += lonDelta;

        checksum = mix(checksum, cast(ulong)id);
        checksum = mix(checksum, cast(ulong)lat);
        checksum = mix(checksum, cast(ulong)lon);
    }

    return StageRun(checksum, ids.empty && lats.empty && lons.empty);
}

private StageRun runDeltaChecked(ref const Workload workload)
    @safe nothrow @nogc
{
    auto ids = WireCursor(workload.ids);
    auto lats = WireCursor(workload.lats);
    auto lons = WireCursor(workload.lons);
    long id;
    long lat;
    long lon;
    ulong checksum;

    foreach (_; 0 .. workload.nodeCount)
    {
        long idDelta;
        long latDelta;
        long lonDelta;
        if (!readTriple(ids, lats, lons, idDelta, latDelta, lonDelta))
            return StageRun(0, false);

        long nextId;
        long nextLat;
        long nextLon;
        if (!checkedAdd(id, idDelta, nextId) ||
            !checkedAdd(lat, latDelta, nextLat) ||
            !checkedAdd(lon, lonDelta, nextLon))
            return StageRun(0, false);

        id = nextId;
        lat = nextLat;
        lon = nextLon;

        checksum = mix(checksum, cast(ulong)id);
        checksum = mix(checksum, cast(ulong)lat);
        checksum = mix(checksum, cast(ulong)lon);
    }

    return StageRun(checksum, ids.empty && lats.empty && lons.empty);
}

private StageRun runCoordinatesUnchecked(ref const Workload workload)
    @safe nothrow @nogc
{
    auto ids = WireCursor(workload.ids);
    auto lats = WireCursor(workload.lats);
    auto lons = WireCursor(workload.lons);
    long id;
    long lat;
    long lon;
    ulong checksum;
    const factor = cast(long)workload.granularity;

    foreach (_; 0 .. workload.nodeCount)
    {
        long idDelta;
        long latDelta;
        long lonDelta;
        if (!readTriple(ids, lats, lons, idDelta, latDelta, lonDelta))
            return StageRun(0, false);

        // This benchmark workload is deliberately constructed so these
        // operations cannot overflow.
        id += idDelta;
        lat += latDelta;
        lon += lonDelta;

        const latNano = workload.latOffset + factor * lat;
        const lonNano = workload.lonOffset + factor * lon;

        checksum = mix(checksum, cast(ulong)id);
        checksum = mix(checksum, cast(ulong)latNano);
        checksum = mix(checksum, cast(ulong)lonNano);
    }

    return StageRun(checksum, ids.empty && lats.empty && lons.empty);
}

private StageRun runCoordinatesChecked(ref const Workload workload)
    @safe nothrow @nogc
{
    auto ids = WireCursor(workload.ids);
    auto lats = WireCursor(workload.lats);
    auto lons = WireCursor(workload.lons);
    long id;
    long lat;
    long lon;
    ulong checksum;
    const factor = cast(long)workload.granularity;

    foreach (_; 0 .. workload.nodeCount)
    {
        long idDelta;
        long latDelta;
        long lonDelta;
        if (!readTriple(ids, lats, lons, idDelta, latDelta, lonDelta))
            return StageRun(0, false);

        // Keep delta accumulation identical to coordinatesUnchecked so the
        // pair isolates only checkedMulAdd versus ordinary mul+add.
        id += idDelta;
        lat += latDelta;
        lon += lonDelta;

        long latNano;
        long lonNano;
        if (!checkedMulAdd(workload.latOffset, factor, lat, latNano) ||
            !checkedMulAdd(workload.lonOffset, factor, lon, lonNano))
            return StageRun(0, false);

        checksum = mix(checksum, cast(ulong)id);
        checksum = mix(checksum, cast(ulong)latNano);
        checksum = mix(checksum, cast(ulong)lonNano);
    }

    return StageRun(checksum, ids.empty && lats.empty && lons.empty);
}

private StageRun runStage(ref const Workload workload, Stage stage)
    @safe nothrow @nogc
{
    final switch (stage)
    {
    case Stage.sint64Decode:
        return runSint64Decode(workload);
    case Stage.deltaUnchecked:
        return runDeltaUnchecked(workload);
    case Stage.deltaChecked:
        return runDeltaChecked(workload);
    case Stage.coordinatesUnchecked:
        return runCoordinatesUnchecked(workload);
    case Stage.coordinatesChecked:
        return runCoordinatesChecked(workload);
    }
}

private string stageName(Stage stage) @safe pure nothrow
{
    final switch (stage)
    {
    case Stage.sint64Decode:
        return "sint64-decode";
    case Stage.deltaUnchecked:
        return "delta-unchecked";
    case Stage.deltaChecked:
        return "delta-checked";
    case Stage.coordinatesUnchecked:
        return "coords-unchecked";
    case Stage.coordinatesChecked:
        return "coords-checked";
    }
}

private size_t percentileIndex(size_t count, size_t numerator, size_t denominator)
    @safe pure nothrow @nogc
{
    if (count <= 1)
        return 0;
    return ((count - 1) * numerator) / denominator;
}

private TimingStats summarize(long[] samples)
{
    sort(samples);
    return TimingStats(
        samples[0],
        samples[percentileIndex(samples.length, 1, 10)],
        samples[percentileIndex(samples.length, 1, 2)],
        samples[percentileIndex(samples.length, 9, 10)],
        samples[$ - 1]);
}

private bool warmup(
    ref const Workload workload,
    Stage stage,
    uint iterations,
    ulong expected)
    @safe nothrow @nogc
{
    foreach (_; 0 .. iterations)
    {
        const run = runStage(workload, stage);
        if (!run.ok || run.checksum != expected)
            return false;
    }
    return true;
}

private long timeStage(
    ref const Workload workload,
    Stage stage,
    uint iterations,
    ulong expected,
    out ulong observable)
    @system
{
    auto sw = StopWatch(AutoStart.yes);
    ulong checksum;
    bool ok = true;
    foreach (_; 0 .. iterations)
    {
        const run = runStage(workload, stage);
        checksum += run.checksum;
        ok = ok && run.ok && run.checksum == expected;
    }
    sw.stop();
    observable = checksum;
    return ok ? sw.peek.total!"nsecs" : -1;
}

private void report(
    Stage stage,
    ref const Workload workload,
    uint iterations,
    BenchResult result)
{
    const denom = cast(double)workload.nodeCount * iterations;
    const p10 = result.timings.p10Nanoseconds / denom;
    const p50 = result.timings.medianNanoseconds / denom;
    const p90 = result.timings.p90Nanoseconds / denom;
    const min = result.timings.minimumNanoseconds / denom;
    const max = result.timings.maximumNanoseconds / denom;
    const delta80 = p50 == 0.0 ? 0.0 : (p90 - p10) / p50 * 100.0;
    const mnode = p50 == 0.0 ? 0.0 : 1000.0 / p50;

    writefln(
        "%-12s p50=%8.3f ns/node %7.2f Mnode/s  p10=%8.3f p90=%8.3f Δ80=%5.1f%%  min=%8.3f max=%8.3f  checksum=%016x",
        stageName(stage), p50, mnode, p10, p90, delta80, min, max,
        result.checksum);
}

/** Run the DenseNodes coordinate-core diagnostic benchmark. */
int main(string[] args) @system
{
    size_t nodeCount = 200_000;
    uint iterations = 1;
    uint samples = 30;
    uint warmupIterations = 2;

    auto options = getopt(
        args,
        "nodes", "Packed values generated per coordinate column", &nodeCount,
        "iterations", "Complete stage runs per timed sample", &iterations,
        "samples", "Timed samples", &samples,
        "warmup", "Untimed stage runs before measurement", &warmupIterations);
    if (options.helpWanted)
    {
        defaultGetoptPrinter("d-osm DenseNodes coordinate-stage benchmark", options.options);
        return 0;
    }
    if (nodeCount == 0 || samples == 0 || iterations != 1)
    {
        stderr.writeln("nodes and samples must be > 0; iterations must be exactly 1");
        return 2;
    }

    auto workload = buildWorkload(nodeCount);
    static immutable Stage[5] stages = [
        Stage.sint64Decode,
        Stage.deltaUnchecked,
        Stage.deltaChecked,
        Stage.coordinatesUnchecked,
        Stage.coordinatesChecked,
    ];
    ulong[5] expected;
    foreach (i, stage; stages)
    {
        const run = runStage(workload, stage);
        if (!run.ok)
        {
            stderr.writefln("stage validation failed: %s", stageName(stage));
            return 3;
        }
        expected[i] = run.checksum;
    }

    if (expected[cast(size_t)Stage.deltaUnchecked] !=
            expected[cast(size_t)Stage.deltaChecked] ||
        expected[cast(size_t)Stage.coordinatesUnchecked] !=
            expected[cast(size_t)Stage.coordinatesChecked])
    {
        stderr.writeln("paired checked/unchecked stage checksum mismatch");
        return 3;
    }

    writeln("d-osm DenseNodes coordinate-stage benchmark");
    writefln("compiler: %s (%s)", __VENDOR__, __VERSION__);
    writefln(
        "nodes: %s  iterations/sample: %s  samples: %s  warmup: %s",
        nodeCount, iterations, samples, warmupIterations);
    writefln(
        "encoded bytes: ids=%s lats=%s lons=%s total=%s",
        workload.ids.length, workload.lats.length, workload.lons.length,
        workload.ids.length + workload.lats.length + workload.lons.length);
    writeln("stages: sint64-decode; checked/unchecked delta accumulation; checked/unchecked nanodegree conversion");
    writeln("excluded: protobuf field scanning, tags, DenseInfo, node views, workload generation and reporting");
    writeln("ordering: rotating five cyclic orders; balanced over each complete five-sample cycle");
    writeln("statistics: min, p10, p50, p90, max; Δ80=(p90-p10)/p50");
    writeln();

    static immutable Stage[5][5] permutations = [
        [
            Stage.sint64Decode,
            Stage.deltaUnchecked,
            Stage.deltaChecked,
            Stage.coordinatesUnchecked,
            Stage.coordinatesChecked,
        ],
        [
            Stage.deltaUnchecked,
            Stage.deltaChecked,
            Stage.coordinatesUnchecked,
            Stage.coordinatesChecked,
            Stage.sint64Decode,
        ],
        [
            Stage.deltaChecked,
            Stage.coordinatesUnchecked,
            Stage.coordinatesChecked,
            Stage.sint64Decode,
            Stage.deltaUnchecked,
        ],
        [
            Stage.coordinatesUnchecked,
            Stage.coordinatesChecked,
            Stage.sint64Decode,
            Stage.deltaUnchecked,
            Stage.deltaChecked,
        ],
        [
            Stage.coordinatesChecked,
            Stage.sint64Decode,
            Stage.deltaUnchecked,
            Stage.deltaChecked,
            Stage.coordinatesUnchecked,
        ],
    ];

    foreach (i, stage; stages)
    {
        if (!warmup(workload, stage, warmupIterations, expected[i]))
        {
            stderr.writefln("warmup consistency failure: %s", stageName(stage));
            return 3;
        }
    }

    long[][5] times;
    foreach (i; 0 .. 5)
        times[i] = new long[samples];
    ulong[5] observables;

    foreach (sample; 0 .. samples)
    {
        const order = permutations[sample % permutations.length];
        foreach (stage; order)
        {
            const index = cast(size_t)stage;
            ulong observed;
            const elapsed = timeStage(
                workload, stage, iterations, expected[index], observed);
            if (elapsed < 0)
            {
                stderr.writefln("benchmark consistency failure: %s", stageName(stage));
                return 3;
            }
            times[index][sample] = elapsed;
            observables[index] ^= observed;
        }
    }

    foreach (i, stage; stages)
    {
        BenchResult result;
        result.timings = summarize(times[i]);
        result.checksum = expected[i];
        result.ok = true;
        report(stage, workload, iterations, result);
    }
    return 0;
}
