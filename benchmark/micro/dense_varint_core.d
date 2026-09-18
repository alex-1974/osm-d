/**
 * Diagnostic microbenchmark for the DenseNodes one-byte varint hot path.
 *
 * The benchmark uses three packed sint64 columns whose generated values all
 * fit into one protobuf varint byte. It compares direct indexed loads, a raw
 * pointer baseline, a minimal slice cursor, the production unsigned varint
 * decoder, and the production signed-varint decoder. The timed work excludes
 * workload generation and reporting.
 *
 * Each timed sample performs exactly one complete stage run. Repeating an
 * identical pure stage inside one timed sample is deliberately forbidden so
 * the optimizer cannot hoist or merge repeated runs.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module benchmark.micro.dense_varint_core;

import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.varint : readSVarint64, readVarint64;
import osm.wire.zigzag : decodeZigZag64;

import std.algorithm.sorting : sort;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, writefln, writeln;

private enum Stage
{
    indexSigned,
    pointerSigned,
    sliceCursorSigned,
    wireVarint,
    wireSVarint,
}

private struct Workload
{
    ubyte[] ids;
    ubyte[] lats;
    ubyte[] lons;
    size_t nodeCount;
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

private struct SliceCursor
{
    const(ubyte)[] remaining;

    this(const(ubyte)[] input) @safe pure nothrow @nogc
    {
        remaining = input;
    }

    pragma(inline, true)
    bool readByte(out ubyte value) @safe pure nothrow @nogc
    {
        if (remaining.length == 0)
        {
            value = 0;
            return false;
        }
        value = remaining[0];
        remaining = remaining[1 .. $];
        return true;
    }

    @property bool empty() const @safe pure nothrow @nogc
    {
        return remaining.length == 0;
    }
}

pragma(inline, true)
private ulong finishChecksum(ulong a, ulong b, ulong c) @safe pure nothrow @nogc
{
    ulong state = 0xcbf2_9ce4_8422_2325UL;
    state = (state ^ a) * 0x0000_0100_0000_01b3UL;
    state = (state ^ b) * 0x0000_0100_0000_01b3UL;
    state = (state ^ c) * 0x0000_0100_0000_01b3UL;
    return state;
}

private long latitudeDelta(size_t nodeIndex) @safe pure nothrow @nogc
{
    static immutable long[8] values = [1, 0, -1, 2, -2, 1, 0, 1];
    return values[nodeIndex & 7];
}

private long longitudeDelta(size_t nodeIndex) @safe pure nothrow @nogc
{
    static immutable long[8] values = [-1, 1, 0, 1, 2, -1, -2, 0];
    return values[nodeIndex & 7];
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
    foreach (i; 0 .. nodeCount)
    {
        appendVarint(result.ids, zigZag64(1));
        appendVarint(result.lats, zigZag64(latitudeDelta(i)));
        appendVarint(result.lons, zigZag64(longitudeDelta(i)));
    }
    return result;
}

private StageRun runIndexSigned(ref const Workload workload)
    @safe pure nothrow @nogc
{
    if (workload.ids.length != workload.nodeCount ||
        workload.lats.length != workload.nodeCount ||
        workload.lons.length != workload.nodeCount)
        return StageRun(0, false);

    ulong a;
    ulong b;
    ulong c;
    foreach (i; 0 .. workload.nodeCount)
    {
        a += cast(ulong)decodeZigZag64(workload.ids[i]);
        b += cast(ulong)decodeZigZag64(workload.lats[i]);
        c += cast(ulong)decodeZigZag64(workload.lons[i]);
    }
    return StageRun(finishChecksum(a, b, c), true);
}

private StageRun runPointerSigned(ref const Workload workload)
    @system pure nothrow @nogc
{
    if (workload.ids.length != workload.nodeCount ||
        workload.lats.length != workload.nodeCount ||
        workload.lons.length != workload.nodeCount)
        return StageRun(0, false);

    auto ids = workload.ids.ptr;
    auto lats = workload.lats.ptr;
    auto lons = workload.lons.ptr;
    ulong a;
    ulong b;
    ulong c;
    foreach (_; 0 .. workload.nodeCount)
    {
        a += cast(ulong)decodeZigZag64(*ids);
        b += cast(ulong)decodeZigZag64(*lats);
        c += cast(ulong)decodeZigZag64(*lons);
        ++ids;
        ++lats;
        ++lons;
    }
    return StageRun(finishChecksum(a, b, c), true);
}

private StageRun runSliceCursorSigned(ref const Workload workload)
    @safe pure nothrow @nogc
{
    auto ids = SliceCursor(workload.ids);
    auto lats = SliceCursor(workload.lats);
    auto lons = SliceCursor(workload.lons);
    ulong a;
    ulong b;
    ulong c;

    foreach (_; 0 .. workload.nodeCount)
    {
        ubyte id;
        ubyte lat;
        ubyte lon;
        if (!ids.readByte(id) || !lats.readByte(lat) || !lons.readByte(lon))
            return StageRun(0, false);
        a += cast(ulong)decodeZigZag64(id);
        b += cast(ulong)decodeZigZag64(lat);
        c += cast(ulong)decodeZigZag64(lon);
    }

    return StageRun(
        finishChecksum(a, b, c),
        ids.empty && lats.empty && lons.empty);
}

private StageRun runWireVarint(ref const Workload workload)
    @system nothrow @nogc
{
    auto ids = WireCursor(workload.ids);
    auto lats = WireCursor(workload.lats);
    auto lons = WireCursor(workload.lons);
    WireStatus status;
    ulong a;
    ulong b;
    ulong c;

    foreach (_; 0 .. workload.nodeCount)
    {
        ulong id;
        ulong lat;
        ulong lon;
        if (!readVarint64(ids, id, status) ||
            !readVarint64(lats, lat, status) ||
            !readVarint64(lons, lon, status))
            return StageRun(0, false);
        a += id;
        b += lat;
        c += lon;
    }

    return StageRun(
        finishChecksum(a, b, c),
        ids.empty && lats.empty && lons.empty);
}

private StageRun runWireSVarint(ref const Workload workload)
    @system nothrow @nogc
{
    auto ids = WireCursor(workload.ids);
    auto lats = WireCursor(workload.lats);
    auto lons = WireCursor(workload.lons);
    WireStatus status;
    ulong a;
    ulong b;
    ulong c;

    foreach (_; 0 .. workload.nodeCount)
    {
        long id;
        long lat;
        long lon;
        if (!readSVarint64(ids, id, status) ||
            !readSVarint64(lats, lat, status) ||
            !readSVarint64(lons, lon, status))
            return StageRun(0, false);
        a += cast(ulong)id;
        b += cast(ulong)lat;
        c += cast(ulong)lon;
    }

    return StageRun(
        finishChecksum(a, b, c),
        ids.empty && lats.empty && lons.empty);
}

private StageRun runStage(ref const Workload workload, Stage stage) @system nothrow @nogc
{
    final switch (stage)
    {
    case Stage.indexSigned: return runIndexSigned(workload);
    case Stage.pointerSigned: return runPointerSigned(workload);
    case Stage.sliceCursorSigned: return runSliceCursorSigned(workload);
    case Stage.wireVarint: return runWireVarint(workload);
    case Stage.wireSVarint: return runWireSVarint(workload);
    }
}

private string stageName(Stage stage) @safe pure nothrow
{
    final switch (stage)
    {
    case Stage.indexSigned: return "index-signed";
    case Stage.pointerSigned: return "pointer-signed";
    case Stage.sliceCursorSigned: return "slice-cursor";
    case Stage.wireVarint: return "wire-varint";
    case Stage.wireSVarint: return "wire-svarint";
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

private long timeStage(
    ref const Workload workload,
    Stage stage,
    ulong expected,
    out ulong observable) @system
{
    auto sw = StopWatch(AutoStart.yes);
    const run = runStage(workload, stage);
    sw.stop();
    observable = run.checksum;
    return run.ok && run.checksum == expected ? sw.peek.total!"nsecs" : -1;
}

private void report(
    Stage stage,
    ref const Workload workload,
    TimingStats timings,
    ulong checksum)
{
    const denom = cast(double)workload.nodeCount;
    const p10 = timings.p10Nanoseconds / denom;
    const p50 = timings.medianNanoseconds / denom;
    const p90 = timings.p90Nanoseconds / denom;
    const min = timings.minimumNanoseconds / denom;
    const max = timings.maximumNanoseconds / denom;
    const delta80 = p50 == 0.0 ? 0.0 : (p90 - p10) / p50 * 100.0;
    const mnode = p50 == 0.0 ? 0.0 : 1000.0 / p50;
    const nvalue = p50 == 0.0 ? 0.0 : p50 / 3.0;

    writefln(
        "%-14s p50=%8.3f ns/node (%6.3f ns/value) %7.2f Mnode/s  p10=%8.3f p90=%8.3f Δ80=%5.1f%%  min=%8.3f max=%8.3f  checksum=%016x",
        stageName(stage), p50, nvalue, mnode, p10, p90, delta80, min, max,
        checksum);
}

/** Run the one-byte DenseNodes varint-core diagnostic benchmark. */
int main(string[] args) @system
{
    size_t nodeCount = 1_000_000;
    uint samples = 30;
    uint warmupIterations = 2;
    uint iterations = 1;

    auto options = getopt(
        args,
        "nodes", "One-byte values generated per column", &nodeCount,
        "iterations", "Must be 1; repeated pure runs are intentionally forbidden", &iterations,
        "samples", "Timed samples", &samples,
        "warmup", "Untimed runs per stage", &warmupIterations);
    if (options.helpWanted)
    {
        defaultGetoptPrinter("osm-d DenseNodes varint-core benchmark", options.options);
        return 0;
    }
    if (nodeCount == 0 || samples == 0 || iterations != 1)
    {
        stderr.writeln("nodes and samples must be > 0; iterations must be exactly 1");
        return 2;
    }

    auto workload = buildWorkload(nodeCount);
    static immutable Stage[5] stages = [
        Stage.indexSigned,
        Stage.pointerSigned,
        Stage.sliceCursorSigned,
        Stage.wireVarint,
        Stage.wireSVarint,
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

    // Signed variants must agree. The unsigned production stage intentionally
    // hashes encoded values instead of ZigZag-decoded values.
    if (expected[0] != expected[1] || expected[0] != expected[2] || expected[0] != expected[4])
    {
        stderr.writeln("signed stage checksum mismatch");
        return 3;
    }

    writeln("osm-d DenseNodes one-byte varint-core benchmark");
    writefln("compiler: %s (%s)", __VENDOR__, __VERSION__);
    writefln(
        "nodes: %s  values: %s  samples: %s  warmup: %s",
        nodeCount, nodeCount * 3, samples, warmupIterations);
    writefln(
        "packed bytes: ids=%s lats=%s lons=%s total=%s",
        workload.ids.length, workload.lats.length, workload.lons.length,
        workload.ids.length + workload.lats.length + workload.lons.length);
    writeln("all generated sint64 values use exactly one protobuf varint byte");
    writeln("one complete stage run per timed sample; repeated pure iterations are forbidden");
    writeln("ordering: rotating five cyclic stage orders");
    writeln("statistics: min, p10, p50, p90, max; Δ80=(p90-p10)/p50");
    writeln();

    foreach (i, stage; stages)
    {
        foreach (_; 0 .. warmupIterations)
        {
            const run = runStage(workload, stage);
            if (!run.ok || run.checksum != expected[i])
            {
                stderr.writefln("warmup consistency failure: %s", stageName(stage));
                return 3;
            }
        }
    }

    long[][5] times;
    foreach (i; 0 .. 5)
        times[i] = new long[samples];

    static immutable Stage[5][5] orders = [
        [Stage.indexSigned, Stage.pointerSigned, Stage.sliceCursorSigned, Stage.wireVarint, Stage.wireSVarint],
        [Stage.pointerSigned, Stage.sliceCursorSigned, Stage.wireVarint, Stage.wireSVarint, Stage.indexSigned],
        [Stage.sliceCursorSigned, Stage.wireVarint, Stage.wireSVarint, Stage.indexSigned, Stage.pointerSigned],
        [Stage.wireVarint, Stage.wireSVarint, Stage.indexSigned, Stage.pointerSigned, Stage.sliceCursorSigned],
        [Stage.wireSVarint, Stage.indexSigned, Stage.pointerSigned, Stage.sliceCursorSigned, Stage.wireVarint],
    ];

    foreach (sample; 0 .. samples)
    {
        const order = orders[sample % orders.length];
        foreach (stage; order)
        {
            const index = cast(size_t)stage;
            ulong observed;
            const elapsed = timeStage(workload, stage, expected[index], observed);
            if (elapsed < 0 || observed != expected[index])
            {
                stderr.writefln("benchmark consistency failure: %s", stageName(stage));
                return 3;
            }
            times[index][sample] = elapsed;
        }
    }

    foreach (i, stage; stages)
        report(stage, workload, summarize(times[i]), expected[i]);

    return 0;
}
