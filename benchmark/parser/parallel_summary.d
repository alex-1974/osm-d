/**
 * Whole-buffer serial/parallel PBF summary benchmark.
 *
 * File loading is outside the measured decode region. Each measured call is
 * preceded by one untimed warm-up of the same mode and requires identical
 * semantic summary counts.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-02
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.benchmark.parser.parallel_summary;

import osm :
    PbfReadStatus,
    PbfReadSummary,
    PbfReader,
    PbfReaderWorkspace;
import osm.pbf :
    PbfParallelReadOptions,
    PbfParallelReader;

import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : stderr, writefln;

private struct NullHandler
{
}

private bool decodeSerial(
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
        "serial read failed: error=%s block=%s offset=%s",
        status.error,
        status.blockSequence,
        status.blockOffset);
    return false;
}

private bool decodeParallel(
    const(ubyte)[] input,
    size_t workers,
    size_t queueCapacity,
    out PbfReadSummary summary)
{
    PbfParallelReader reader;
    PbfParallelReadOptions options;
    options.workerCount = workers;
    options.queueCapacity = queueCapacity;

    PbfReadStatus status;
    if (reader.readSummary(input, options, summary, status))
        return true;

    stderr.writefln(
        "parallel read failed: error=%s block=%s offset=%s",
        status.error,
        status.blockSequence,
        status.blockOffset);
    return false;
}

private void printSummary(size_t bytes, ref const PbfReadSummary summary)
{
    writefln("bytes=%s", bytes);
    writefln("header_blocks=%s", summary.headerBlocks);
    writefln("data_blocks=%s", summary.dataBlocks);
    writefln("primitive_groups=%s", summary.primitiveGroups);
    writefln("nodes=%s", summary.nodes);
    writefln("ways=%s", summary.ways);
    writefln("relations=%s", summary.relations);
    writefln("tags=%s", summary.tags);
}

int main(string[] args)
{
    bool measure;
    size_t offset = 1;

    if (args.length > 1 && args[1] == "--measure")
    {
        measure = true;
        offset = 2;
    }

    if (args.length <= offset)
    {
        stderr.writefln(
            "usage: %s [--measure] serial FILE | parallel WORKERS QUEUE FILE",
            args[0]);
        return 2;
    }

    const mode = args[offset];

    string filename;
    size_t workers;
    size_t queueCapacity;

    if (mode == "serial")
    {
        if (args.length != offset + 2)
            return 2;
        filename = args[offset + 1];
    }
    else if (mode == "parallel")
    {
        if (args.length != offset + 4)
            return 2;
        workers = to!size_t(args[offset + 1]);
        queueCapacity = to!size_t(args[offset + 2]);
        filename = args[offset + 3];

        if (workers == 0 || queueCapacity == 0)
        {
            stderr.writeln("benchmark requires explicit positive workers/queue");
            return 2;
        }
    }
    else
    {
        stderr.writefln("unknown mode: %s", mode);
        return 2;
    }

    auto storage = cast(ubyte[])read(filename);
    const input = cast(const(ubyte)[])storage;

    PbfReadSummary warm;
    PbfReadSummary result;
    PbfReaderWorkspace serialWorkspace;

    if (mode == "serial")
    {
        if (!decodeSerial(input, serialWorkspace, warm))
            return 1;

        if (!measure)
        {
            printSummary(storage.length, warm);
            return 0;
        }

        StopWatch sw = StopWatch(AutoStart.yes);
        if (!decodeSerial(input, serialWorkspace, result))
            return 1;
        sw.stop();

        if (result != warm)
            return 1;

        writefln("elapsed_ns=%s", sw.peek.total!"nsecs");
    }
    else
    {
        if (!decodeParallel(input, workers, queueCapacity, warm))
            return 1;

        if (!measure)
        {
            printSummary(storage.length, warm);
            return 0;
        }

        StopWatch sw = StopWatch(AutoStart.yes);
        if (!decodeParallel(input, workers, queueCapacity, result))
            return 1;
        sw.stop();

        if (result != warm)
            return 1;

        writefln("elapsed_ns=%s", sw.peek.total!"nsecs");
    }

    printSummary(storage.length, result);
    return 0;
}
