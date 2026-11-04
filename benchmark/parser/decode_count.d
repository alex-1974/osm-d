/**
 * Whole-buffer OSMPBF decode-count benchmark for the production PbfReader.
 *
 * The input file is loaded before the measured parser region. The benchmark
 * exercises the same consumer-facing whole-file orchestration shipped by
 * osm-d and observes only semantic counts; no owned OSM model is materialized.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-22
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.benchmark.parser.decode_count;

import osm :
    PbfReadStatus,
    PbfReadSummary,
    PbfReader,
    PbfReaderWorkspace;

import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : stderr, writefln;

private struct NullHandler
{
}

private bool decodeBuffer(
    const(ubyte)[] input,
    ref PbfReaderWorkspace workspace,
    out PbfReadSummary summary)
{
    PbfReader reader;
    NullHandler handler;
    PbfReadStatus status;

    if (reader.read(input, workspace, handler, summary, status))
        return true;

    stderr.writefln(
        "PBF read failed: error=%s block=%s block_offset=%s",
        status.error,
        status.blockSequence,
        status.blockOffset);
    return false;
}

private void printCounts(size_t byteCount, ref const PbfReadSummary counts)
{
    writefln("bytes=%s", byteCount);
    writefln("header_blocks=%s", counts.headerBlocks);
    writefln("data_blocks=%s", counts.dataBlocks);
    writefln("primitive_groups=%s", counts.primitiveGroups);
    writefln("nodes=%s", counts.nodes);
    writefln("ways=%s", counts.ways);
    writefln("relations=%s", counts.relations);
    writefln("tags=%s", counts.tags);
}

int main(string[] args)
{
    bool measure;
    string filename;

    if (args.length == 2)
    {
        filename = args[1];
    }
    else if (args.length == 3 && args[1] == "--measure")
    {
        measure = true;
        filename = args[2];
    }
    else
    {
        stderr.writefln("usage: %s [--measure] FILE.osm.pbf", args[0]);
        return 2;
    }

    auto storage = cast(ubyte[])read(filename);
    const input = cast(const(ubyte)[])storage;

    PbfReaderWorkspace workspace;
    PbfReadSummary counts;

    if (!measure)
    {
        if (!decodeBuffer(input, workspace, counts))
            return 1;

        printCounts(storage.length, counts);
        return 0;
    }

    // Untimed warm-up primes reusable reader workspace before measurement.
    PbfReadSummary warmCounts;
    if (!decodeBuffer(input, workspace, warmCounts))
        return 1;

    StopWatch stopwatch = StopWatch(AutoStart.yes);
    if (!decodeBuffer(input, workspace, counts))
        return 1;
    stopwatch.stop();

    if (counts != warmCounts)
    {
        stderr.writeln("non-deterministic counts between warm-up and measured decode");
        return 1;
    }

    writefln("elapsed_ns=%s", stopwatch.peek.total!"nsecs");
    printCounts(storage.length, counts);
    return 0;
}
