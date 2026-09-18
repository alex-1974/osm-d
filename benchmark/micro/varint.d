/**
 * Microbenchmark for protobuf unsigned 64-bit varint decoding.
 *
 * The benchmark measures the production slice-backed `WireCursor` against a
 * benchmark-local legacy pointer cursor that mirrors the pre-ADR-0008 design.
 * Both decoder hot paths use explicit inlining so the comparison isolates the
 * cursor representation rather than a package/module boundary artifact.
 *
 * Input generation, correctness checks, allocation, sample ordering,
 * statistics and reporting are outside the timed region. Paired runs alternate
 * AB/BA order, giving an ABBA pattern over each two-sample block.
 *
 * This is a CPU/cache microbenchmark. It deliberately does not include file
 * I/O, decompression, PBF framing or OSM validation and must not be quoted as
 * end-to-end parser throughput.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module benchmark.micro.varint;

import osm.wire.cursor : WireCursor;
import osm.wire.error : WireError, WireStatus;
import osm.wire.varint : readVarint64;

import std.algorithm.sorting : sort;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, writefln, writeln;

private enum WorkloadProfile
{
    oneByte,
    twoByte,
    mixed,
    longValues,
}

private enum ImplementationSelection
{
    all,
    production,
    pointerReference,
}

private struct Workload
{
    string name;
    ubyte[] bytes;
    size_t valueCount;
    ulong checksum;
}

private struct DecodeRun
{
    ulong checksum;
    size_t valueCount;
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

private struct PairBenchResult
{
    BenchResult production;
    BenchResult pointerReference;
}

/**
 * Benchmark-local legacy cursor using the pre-ADR-0008 pointer representation.
 *
 * Notes:
 *   This exists only as a performance reference. Production code must use
 *   `osm.wire.cursor.WireCursor`.
 */
private struct PointerReferenceCursor
{
private:
    const(ubyte)* ptr;
    size_t remainingBytes;
    size_t consumed;

public:
    this(scope const(ubyte)[] input) @system nothrow @nogc
    {
        ptr = input.ptr;
        remainingBytes = input.length;
        consumed = 0;
    }

    pragma(inline, true)
    @property bool empty() const @safe pure nothrow @nogc
    {
        return remainingBytes == 0;
    }

    pragma(inline, true)
    @property size_t offset() const @safe pure nothrow @nogc
    {
        return consumed;
    }

    pragma(inline, true)
    bool readByte(out ubyte value) @trusted nothrow @nogc
    {
        if (remainingBytes == 0)
            return false;

        value = *ptr++;
        --remainingBytes;
        ++consumed;
        return true;
    }
}

/** Legacy pointer-based varint decoder retained only for benchmark comparison. */
pragma(inline, true)
private bool readVarint64PointerReference(
    ref PointerReferenceCursor cursor,
    out ulong value,
    out WireStatus status)
    @safe nothrow @nogc
{
    const start = cursor.offset;

    ubyte first;
    if (!cursor.readByte(first))
    {
        value = 0;
        status = WireStatus.failure(WireError.truncatedVarint, start);
        return false;
    }

    if ((first & 0x80) == 0)
    {
        value = first;
        status = WireStatus.init;
        return true;
    }

    ulong result = first & 0x7fUL;
    uint shift = 7;

    foreach (_; 1 .. 9)
    {
        ubyte b;
        if (!cursor.readByte(b))
        {
            value = 0;
            status = WireStatus.failure(WireError.truncatedVarint, start);
            return false;
        }

        result |= cast(ulong)(b & 0x7f) << shift;
        if ((b & 0x80) == 0)
        {
            value = result;
            status = WireStatus.init;
            return true;
        }
        shift += 7;
    }

    ubyte last;
    if (!cursor.readByte(last))
    {
        value = 0;
        status = WireStatus.failure(WireError.truncatedVarint, start);
        return false;
    }

    if (last > 1)
    {
        value = 0;
        status = WireStatus.failure(WireError.varintOverflow, start);
        return false;
    }

    result |= cast(ulong)last << 63;
    value = result;
    status = WireStatus.init;
    return true;
}

private DecodeRun decodeProduction(scope const(ubyte)[] bytes)
    @safe nothrow @nogc
{
    auto cursor = WireCursor(bytes);
    WireStatus status;
    ulong checksum;
    size_t count;

    while (!cursor.empty)
    {
        ulong value;
        if (!readVarint64(cursor, value, status))
            return DecodeRun(checksum, count, false);

        checksum += value;
        ++count;
    }

    return DecodeRun(checksum, count, true);
}

private DecodeRun decodePointerReference(scope const(ubyte)[] bytes)
    @system nothrow @nogc
{
    auto cursor = PointerReferenceCursor(bytes);
    WireStatus status;
    ulong checksum;
    size_t count;

    while (!cursor.empty)
    {
        ulong value;
        if (!readVarint64PointerReference(cursor, value, status))
            return DecodeRun(checksum, count, false);

        checksum += value;
        ++count;
    }

    return DecodeRun(checksum, count, true);
}

private ulong xorshift64(ref ulong state) @safe pure nothrow @nogc
{
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    return state;
}

private ulong profileValue(WorkloadProfile profile, ref ulong state)
    @safe pure nothrow @nogc
{
    const random = xorshift64(state);

    final switch (profile)
    {
    case WorkloadProfile.oneByte:
        return random & 0x7fUL;
    case WorkloadProfile.twoByte:
        return 128UL + random % (16_384UL - 128UL);
    case WorkloadProfile.mixed:
        const bucket = random % 100;
        if (bucket < 70)
            return random & 0x7fUL;
        if (bucket < 90)
            return 128UL + random % (16_384UL - 128UL);
        if (bucket < 98)
            return 16_384UL + random % ((1UL << 21) - 16_384UL);
        if (bucket < 99)
            return (1UL << 21) + random % ((1UL << 35) - (1UL << 21));
        return ulong.max - (random & 0xffffUL);
    case WorkloadProfile.longValues:
        return (1UL << 63) | (random & 0x7fff_ffff_ffff_ffffUL);
    }
}

private size_t encodeVarint(ulong value, ubyte[] destination)
    @safe nothrow @nogc
{
    size_t count;
    while (value >= 0x80)
    {
        destination[count++] = cast(ubyte)((value & 0x7f) | 0x80);
        value >>= 7;
    }
    destination[count++] = cast(ubyte)value;
    return count;
}

private string profileName(WorkloadProfile profile) @safe pure nothrow @nogc
{
    final switch (profile)
    {
    case WorkloadProfile.oneByte: return "one-byte";
    case WorkloadProfile.twoByte: return "two-byte";
    case WorkloadProfile.mixed: return "mixed";
    case WorkloadProfile.longValues: return "long";
    }
}

private Workload makeWorkload(WorkloadProfile profile, size_t valueCount)
{
    auto storage = new ubyte[valueCount * 10];
    size_t used;
    ulong checksum;
    ulong state = 0x9e37_79b9_7f4a_7c15UL ^ cast(ulong)profile;

    foreach (_; 0 .. valueCount)
    {
        const value = profileValue(profile, state);
        used += encodeVarint(value, storage[used .. used + 10]);
        checksum += value;
    }

    storage.length = used;
    return Workload(profileName(profile), storage, valueCount, checksum);
}

private bool checkSingle(
    scope const(ubyte)[] bytes,
    bool expectedSuccess,
    ulong expectedValue,
    WireError expectedError)
    @system
{
    WireStatus productionStatus;
    ulong productionValue;
    auto productionCursor = WireCursor(bytes);
    const productionSuccess = readVarint64(
        productionCursor, productionValue, productionStatus);

    WireStatus pointerStatus;
    ulong pointerValue;
    auto pointerCursor = PointerReferenceCursor(bytes);
    const pointerSuccess = readVarint64PointerReference(
        pointerCursor, pointerValue, pointerStatus);

    if (productionSuccess != pointerSuccess || productionSuccess != expectedSuccess)
        return false;

    if (expectedSuccess)
        return productionValue == expectedValue && pointerValue == expectedValue;

    return productionStatus.error == expectedError &&
           pointerStatus.error == expectedError;
}

private bool validateImplementations() @system
{
    const(ubyte)[] zeroNonMinimal = [0x80, 0x00];
    if (!checkSingle(zeroNonMinimal, true, 0, WireError.none))
        return false;

    const(ubyte)[] truncated = [0x80];
    if (!checkSingle(truncated, false, 0, WireError.truncatedVarint))
        return false;

    const(ubyte)[] overflow = [
        0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x02,
    ];
    if (!checkSingle(overflow, false, 0, WireError.varintOverflow))
        return false;

    const(ubyte)[] maximum = [
        0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
    ];
    return checkSingle(maximum, true, ulong.max, WireError.none);
}

private bool validateRun(
    scope const Workload workload,
    uint iterations,
    const DecodeRun run)
    @safe pure nothrow @nogc
{
    return run.ok &&
           run.valueCount == workload.valueCount * iterations &&
           run.checksum == workload.checksum * iterations;
}

private bool warmup(alias decoder)(scope const Workload workload, uint iterations)
    @system
{
    foreach (_; 0 .. iterations)
    {
        const run = decoder(workload.bytes);
        if (!run.ok || run.valueCount != workload.valueCount ||
            run.checksum != workload.checksum)
            return false;
    }
    return true;
}

private long timeDecoder(alias decoder)(
    scope const Workload workload,
    uint iterations,
    out ulong observableChecksum)
    @system
{
    auto stopwatch = StopWatch(AutoStart.yes);
    ulong aggregateChecksum;
    size_t aggregateCount;
    bool ok = true;

    foreach (_; 0 .. iterations)
    {
        const run = decoder(workload.bytes);
        aggregateChecksum += run.checksum;
        aggregateCount += run.valueCount;
        ok = ok && run.ok;
    }

    stopwatch.stop();
    observableChecksum = aggregateChecksum;

    const aggregate = DecodeRun(aggregateChecksum, aggregateCount, ok);
    if (!validateRun(workload, iterations, aggregate))
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

private BenchResult measureSingle(alias decoder)(
    scope const Workload workload,
    uint iterations,
    uint samples,
    uint warmupIterations)
    @system
{
    if (!warmup!decoder(workload, warmupIterations))
        return BenchResult.init;

    auto timings = new long[samples];
    ulong observableChecksum;

    foreach (sample; 0 .. samples)
    {
        ulong checksum;
        const elapsed = timeDecoder!decoder(workload, iterations, checksum);
        if (elapsed < 0)
            return BenchResult.init;
        timings[sample] = elapsed;
        observableChecksum += checksum ^ cast(ulong)sample;
    }

    return summarize(timings, observableChecksum);
}

private PairBenchResult measurePair(
    scope const Workload workload,
    uint iterations,
    uint samples,
    uint warmupIterations)
    @system
{
    if (!warmup!decodeProduction(workload, warmupIterations) ||
        !warmup!decodePointerReference(workload, warmupIterations))
        return PairBenchResult.init;

    auto productionTimings = new long[samples];
    auto pointerTimings = new long[samples];
    ulong productionChecksum;
    ulong pointerChecksum;

    foreach (sample; 0 .. samples)
    {
        long productionElapsed;
        long pointerElapsed;
        ulong productionObserved;
        ulong pointerObserved;

        if ((sample & 1) == 0)
        {
            productionElapsed = timeDecoder!decodeProduction(
                workload, iterations, productionObserved);
            pointerElapsed = timeDecoder!decodePointerReference(
                workload, iterations, pointerObserved);
        }
        else
        {
            pointerElapsed = timeDecoder!decodePointerReference(
                workload, iterations, pointerObserved);
            productionElapsed = timeDecoder!decodeProduction(
                workload, iterations, productionObserved);
        }

        if (productionElapsed < 0 || pointerElapsed < 0)
            return PairBenchResult.init;

        productionTimings[sample] = productionElapsed;
        pointerTimings[sample] = pointerElapsed;
        productionChecksum += productionObserved ^ cast(ulong)sample;
        pointerChecksum += pointerObserved ^ cast(ulong)sample;
    }

    return PairBenchResult(
        summarize(productionTimings, productionChecksum),
        summarize(pointerTimings, pointerChecksum));
}

private void report(
    string implementation,
    scope const Workload workload,
    uint iterations,
    const BenchResult result)
{
    const totalValues = cast(double)workload.valueCount * iterations;
    const totalBytes = cast(double)workload.bytes.length * iterations;
    const medianSeconds = cast(double)result.timings.medianNanoseconds /
        1_000_000_000.0;
    const medianNsPerValue =
        cast(double)result.timings.medianNanoseconds / totalValues;
    const p10NsPerValue = cast(double)result.timings.p10Nanoseconds / totalValues;
    const p90NsPerValue = cast(double)result.timings.p90Nanoseconds / totalValues;
    const minNsPerValue = cast(double)result.timings.minimumNanoseconds / totalValues;
    const maxNsPerValue = cast(double)result.timings.maximumNanoseconds / totalValues;
    const megaValuesPerSecond = totalValues / medianSeconds / 1_000_000.0;
    const mebiBytesPerSecond = totalBytes / medianSeconds / (1024.0 * 1024.0);
    const spreadPercent = result.timings.medianNanoseconds == 0
        ? 0.0
        : cast(double)(result.timings.p90Nanoseconds - result.timings.p10Nanoseconds) /
            result.timings.medianNanoseconds * 100.0;

    writefln(
        "%-10s %-12s p50=%7.3f ns/value %8.2f Mval/s %8.2f MiB/s  " ~
        "p10=%7.3f p90=%7.3f Δ80=%5.1f%%  min=%7.3f max=%7.3f  checksum=%016x",
        workload.name,
        implementation,
        medianNsPerValue,
        megaValuesPerSecond,
        mebiBytesPerSecond,
        p10NsPerValue,
        p90NsPerValue,
        spreadPercent,
        minNsPerValue,
        maxNsPerValue,
        result.checksum);
}

private bool parseProfile(string name, out WorkloadProfile profile)
    @safe pure nothrow
{
    switch (name)
    {
    case "one-byte": profile = WorkloadProfile.oneByte; return true;
    case "two-byte": profile = WorkloadProfile.twoByte; return true;
    case "mixed": profile = WorkloadProfile.mixed; return true;
    case "long": profile = WorkloadProfile.longValues; return true;
    default: profile = WorkloadProfile.init; return false;
    }
}

private bool parseImplementation(
    string name,
    out ImplementationSelection implementation)
    @safe pure nothrow
{
    switch (name)
    {
    case "all":
    case "both":
        implementation = ImplementationSelection.all;
        return true;
    case "production":
    case "slice":
    case "slice-prod":
        implementation = ImplementationSelection.production;
        return true;
    case "pointer":
    case "pointer-ref":
    case "legacy-pointer":
        implementation = ImplementationSelection.pointerReference;
        return true;
    default:
        implementation = ImplementationSelection.init;
        return false;
    }
}

private bool runWorkload(
    scope const Workload workload,
    ImplementationSelection implementation,
    uint iterations,
    uint samples,
    uint warmupIterations)
    @system
{
    final switch (implementation)
    {
    case ImplementationSelection.all:
        const pair = measurePair(workload, iterations, samples, warmupIterations);
        if (!pair.production.ok || !pair.pointerReference.ok)
            return false;
        report("production", workload, iterations, pair.production);
        report("pointer-ref", workload, iterations, pair.pointerReference);
        return true;

    case ImplementationSelection.production:
        const result = measureSingle!decodeProduction(
            workload, iterations, samples, warmupIterations);
        if (!result.ok)
            return false;
        report("production", workload, iterations, result);
        return true;

    case ImplementationSelection.pointerReference:
        const result = measureSingle!decodePointerReference(
            workload, iterations, samples, warmupIterations);
        if (!result.ok)
            return false;
        report("pointer-ref", workload, iterations, result);
        return true;
    }
}

/**
 * Run the varint microbenchmark.
 *
 * Command-line options:
 *
 * - `--values`: number of values in one generated stream;
 * - `--iterations`: full-stream decodes per timed sample;
 * - `--samples`: number of timed samples;
 * - `--warmup`: untimed full-stream decodes per implementation and profile;
 * - `--profile`: `all`, `one-byte`, `two-byte`, `mixed`, or `long`;
 * - `--implementation`: `all`, `production`, or `pointer-ref`.
 *
 * Returns:
 *   Zero on success, non-zero for invalid arguments or a decoder-consistency
 *   failure.
 */
int main(string[] args) @system
{
    size_t valueCount = 1_000_000;
    uint iterations = 20;
    uint samples = 30;
    uint warmupIterations = 3;
    string selectedProfile = "all";
    string selectedImplementation = "all";

    auto options = getopt(
        args,
        "values", "Values encoded into each benchmark stream", &valueCount,
        "iterations", "Full-stream decodes per timed sample", &iterations,
        "samples", "Timed samples; robust quantiles are reported", &samples,
        "warmup", "Untimed full-stream decodes before measurement", &warmupIterations,
        "profile", "all|one-byte|two-byte|mixed|long", &selectedProfile,
        "implementation", "all|production|pointer-ref", &selectedImplementation);

    if (options.helpWanted)
    {
        defaultGetoptPrinter(
            "osm-d protobuf varint microbenchmark",
            options.options);
        return 0;
    }

    if (valueCount == 0 || iterations == 0 || samples == 0)
    {
        stderr.writeln("values, iterations and samples must all be greater than zero");
        return 2;
    }
    if (samples > 100_000)
    {
        stderr.writeln("samples is unreasonably large");
        return 2;
    }
    if (valueCount > size_t.max / 10)
    {
        stderr.writeln("values is too large for the benchmark buffer");
        return 2;
    }

    ImplementationSelection implementation;
    if (!parseImplementation(selectedImplementation, implementation))
    {
        stderr.writefln("unknown implementation: %s", selectedImplementation);
        return 2;
    }

    if (!validateImplementations())
    {
        stderr.writeln("production slice and pointer reference decoders disagree");
        return 3;
    }

    writeln("osm-d varint microbenchmark");
    writefln("compiler: %s (%s)", __VENDOR__, __VERSION__);
    writefln(
        "values/profile: %s  iterations/sample: %s  samples: %s  warmup: %s",
        valueCount,
        iterations,
        samples,
        warmupIterations);
    if (implementation == ImplementationSelection.all)
        writeln("ordering: paired AB/BA (ABBA over each two-sample pair)");
    else
        writeln("ordering: single implementation process/run");
    writeln("statistics: min, p10, p50, p90, max; Δ80=(p90-p10)/p50");
    writeln("workload generation, validation, sorting and reporting are excluded");
    writeln();

    static immutable WorkloadProfile[4] allProfiles = [
        WorkloadProfile.oneByte,
        WorkloadProfile.twoByte,
        WorkloadProfile.mixed,
        WorkloadProfile.longValues,
    ];

    if (selectedProfile == "all")
    {
        foreach (profile; allProfiles)
        {
            auto workload = makeWorkload(profile, valueCount);
            if (!runWorkload(
                    workload,
                    implementation,
                    iterations,
                    samples,
                    warmupIterations))
            {
                stderr.writeln("decoder failed workload consistency validation");
                return 3;
            }
        }
    }
    else
    {
        WorkloadProfile profile;
        if (!parseProfile(selectedProfile, profile))
        {
            stderr.writefln("unknown profile: %s", selectedProfile);
            return 2;
        }

        auto workload = makeWorkload(profile, valueCount);
        if (!runWorkload(
                workload,
                implementation,
                iterations,
                samples,
                warmupIterations))
        {
            stderr.writeln("decoder failed workload consistency validation");
            return 3;
        }
    }

    return 0;
}
