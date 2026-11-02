/**
 * Whole-buffer PBF GC-allocation baseline for PbfReader workspace reuse.
 *
 * The encoded file is loaded before the reported decode passes. Each pass uses
 * the same caller-owned PbfReaderWorkspace and a no-op semantic handler. The
 * benchmark reports bytes allocated through D's GC by the current thread and
 * GC collection counts for each complete validated decode.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-02
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.benchmark.parser.memory_baseline;

import core.memory : GC;

import osm :
    PbfReadStatus,
    PbfReadSummary,
    PbfReader,
    PbfReaderWorkspace;

import std.conv : to;
import std.file : read;
import std.stdio : stderr, writefln;

private struct NullHandler
{
}

private bool decode(
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

private void printSummary(ref const PbfReadSummary summary)
{
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
    size_t passes = 3;
    string filename;

    if (args.length == 2)
    {
        filename = args[1];
    }
    else if (args.length == 4 && args[1] == "--passes")
    {
        passes = to!size_t(args[2]);
        filename = args[3];
    }
    else
    {
        stderr.writefln("usage: %s [--passes N] FILE.osm.pbf", args[0]);
        return 2;
    }

    if (passes < 2)
    {
        stderr.writeln("--passes must be at least 2");
        return 2;
    }

    auto storage = cast(ubyte[])read(filename);
    const input = cast(const(ubyte)[])storage;

    // Keep input loading and startup allocations out of the per-decode deltas.
    GC.collect();

    PbfReaderWorkspace workspace;
    PbfReadSummary reference;

    writefln("input_bytes=%s", storage.length);
    writefln("passes=%s", passes);

    foreach (pass; 0 .. passes)
    {
        const allocatedBefore = GC.allocatedInCurrentThread();
        const profileBefore = GC.profileStats();

        PbfReadSummary summary;
        if (!decode(input, workspace, summary))
            return 1;

        const profileAfter = GC.profileStats();
        const allocatedAfter = GC.allocatedInCurrentThread();

        if (pass == 0)
        {
            reference = summary;
            printSummary(summary);
        }
        else if (summary != reference)
        {
            stderr.writefln("semantic summary changed on pass %s", pass + 1);
            return 1;
        }

        writefln(
            "pass=%s gc_allocated_bytes=%s gc_collections=%s",
            pass + 1,
            allocatedAfter - allocatedBefore,
            profileAfter.numCollections - profileBefore.numCollections);
    }

    return 0;
}
