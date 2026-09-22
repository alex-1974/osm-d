/**
 * Whole-buffer OSMPBF decode-count benchmark for the production osm-d decoder.
 *
 * The input file is loaded before the measured/parser region by the eventual
 * benchmark harness. This executable currently establishes semantic parity:
 *
 *   compressed PBF bytes
 *   -> framing
 *   -> Blob validation/decompression
 *   -> HeaderBlock + required-feature validation
 *   -> PrimitiveBlock/StringTable
 *   -> PrimitiveGroup structural validation
 *   -> complete Node/Way/Relation semantic preflight + emission
 *   -> node/way/relation/tag counts
 *
 * No owned OSM model is materialized.
 */
module benchmark.parser.decode_count;

import osm.io.pbf.blob :
    BlobView,
    decodeBlob;
import osm.io.pbf.blob_header :
    BlobKind;
import osm.io.pbf.decompress :
    BlobPayloadView,
    decodeBlobPayloadInto,
    requiredOutputSize;
import osm.io.pbf.dense_nodes :
    DenseNodeDecodeSummary,
    DenseNodeView,
    decodeDenseNodes;
import osm.io.pbf.error :
    PbfStatus;
import osm.io.pbf.features :
    HeaderFeatureAssessment,
    HeaderFeatureSupport,
    validateRequiredFeatures;
import osm.io.pbf.framing :
    FileBlockView,
    FrameReadResult,
    readFileBlock;
import osm.io.pbf.header_block :
    HeaderBlockView,
    decodeHeaderBlock;
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
import osm.io.pbf.relation :
    RelationDecodeSummary,
    RelationView,
    decodeRelations;
import osm.io.pbf.string_table :
    StringRef,
    StringTableView,
    buildStringTableView;
import osm.io.pbf.way :
    WayDecodeSummary,
    WayView,
    decodeWays;
import osm.wire.cursor :
    WireCursor;

import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : stderr, writefln;

private struct Counts
{
    ulong nodes;
    ulong ways;
    ulong relations;
    ulong tags;
    ulong headerBlocks;
    ulong dataBlocks;
    ulong primitiveGroups;
}

private struct Scratch
{
    ubyte[] decompressionBuffer;
    StringRef[] stringRefs;
}

private struct NullSink
{
    void putDenseNodeScalars(long, long, long) @safe nothrow @nogc
    {
    }

    void put(DenseNodeView) @safe nothrow @nogc
    {
    }

    void put(NodeView) @safe nothrow @nogc
    {
    }

    void put(WayView) @safe nothrow @nogc
    {
    }

    void put(RelationView) @safe nothrow @nogc
    {
    }
}

private bool reportFailure(string stage, PbfStatus status)
{
    stderr.writefln(
        "%s failed: error=%s offset=%s field=%s",
        stage,
        status.error,
        status.offset,
        status.fieldNumber);
    return false;
}

private bool decodeDataBlock(
    const(ubyte)[] payloadBytes,
    ref StringRef[] stringRefs,
    ref Counts counts)
{
    PbfStatus status;

    PrimitiveBlockLayout block;
    if (!decodePrimitiveBlockLayout(payloadBytes, block, status))
        return reportFailure("PrimitiveBlock", status);

    if (stringRefs.length < block.stringCount)
        stringRefs.length = block.stringCount;

    StringTableView table;
    if (!buildStringTableView(
        block,
        stringRefs[0 .. block.stringCount],
        table,
        status))
    {
        return reportFailure("StringTable", status);
    }

    auto groups = block.primitiveGroups;
    while (!groups.empty)
    {
        const groupRef = groups.front;
        groups.popFront();

        PrimitiveGroupLayout group;
        if (!decodePrimitiveGroupLayout(groupRef.bytes, group, status))
            return reportFailure("PrimitiveGroup", status);

        if (group.changeSetOccurrences != 0)
        {
            stderr.writefln(
                "PrimitiveGroup contains unsupported ChangeSet occurrences: %s",
                group.changeSetOccurrences);
            return false;
        }

        NullSink sink;

        DenseNodeDecodeSummary denseSummary;
        if (!decodeDenseNodes(
            block,
            group,
            table,
            sink,
            denseSummary,
            status))
        {
            return reportFailure("DenseNodes", status);
        }

        NodeDecodeSummary nodeSummary;
        if (!decodeNodes(
            block,
            group,
            table,
            sink,
            nodeSummary,
            status))
        {
            return reportFailure("Node", status);
        }

        WayDecodeSummary waySummary;
        if (!decodeWays(
            block,
            group,
            table,
            sink,
            waySummary,
            status))
        {
            return reportFailure("Way", status);
        }

        RelationDecodeSummary relationSummary;
        if (!decodeRelations(
            block,
            group,
            table,
            sink,
            relationSummary,
            status))
        {
            return reportFailure("Relation", status);
        }

        counts.nodes += denseSummary.nodeCount;
        counts.nodes += nodeSummary.nodeCount;
        counts.ways += waySummary.wayCount;
        counts.relations += relationSummary.relationCount;

        counts.tags += denseSummary.tagCount;
        counts.tags += nodeSummary.tagCount;
        counts.tags += waySummary.tagCount;
        counts.tags += relationSummary.tagCount;

        ++counts.primitiveGroups;
    }

    ++counts.dataBlocks;
    return true;
}

private bool decodeBuffer(
    const(ubyte)[] input,
    ref Scratch scratch,
    out Counts counts)
{
    counts = Counts.init;

    auto cursor = WireCursor(input);
    bool sawHeader;
    bool sawData;
    ulong sequence;

    while (true)
    {
        FileBlockView fileBlock;
        PbfStatus status;

        const frameResult =
            readFileBlock(cursor, sequence, fileBlock, status);

        final switch (frameResult)
        {
            case FrameReadResult.endOfInput:
                break;

            case FrameReadResult.error:
                return reportFailure("framing", status);

            case FrameReadResult.block:
                BlobView blob;
                if (!decodeBlob(fileBlock.blob, blob, status))
                    return reportFailure("Blob", status);

                const outputSize = requiredOutputSize(blob);
                if (scratch.decompressionBuffer.length < outputSize)
                    scratch.decompressionBuffer.length = outputSize;

                BlobPayloadView payload;
                if (!decodeBlobPayloadInto(
                    blob,
                    scratch.decompressionBuffer,
                    payload,
                    status))
                {
                    return reportFailure("Blob payload", status);
                }

                final switch (fileBlock.header.kind)
                {
                    case BlobKind.osmHeader:
                        if (sawHeader || sawData)
                        {
                            stderr.writefln(
                                "invalid file-level block order: OSMHeader at sequence %s",
                                sequence);
                            return false;
                        }

                        HeaderBlockView header;
                        if (!decodeHeaderBlock(payload.bytes, header, status))
                            return reportFailure("HeaderBlock", status);

                        HeaderFeatureAssessment assessment;
                        if (!validateRequiredFeatures(
                            header,
                            HeaderFeatureSupport.allKnown(),
                            assessment,
                            status))
                        {
                            return reportFailure("HeaderBlock features", status);
                        }

                        sawHeader = true;
                        ++counts.headerBlocks;
                        break;

                    case BlobKind.osmData:
                        if (!sawHeader)
                        {
                            stderr.writefln(
                                "OSMData encountered before OSMHeader at sequence %s",
                                sequence);
                            return false;
                        }

                        sawData = true;
                        if (!decodeDataBlock(
                            payload.bytes,
                            scratch.stringRefs,
                            counts))
                        {
                            return false;
                        }
                        break;

                    case BlobKind.unknown:
                        stderr.writefln(
                            "unsupported file block type at sequence %s",
                            sequence);
                        return false;
                }

                ++sequence;
                continue;
        }

        break;
    }

    if (!sawHeader)
    {
        stderr.writeln("missing OSMHeader block");
        return false;
    }

    return true;
}

private void printCounts(size_t byteCount, ref const Counts counts)
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

    Scratch scratch;
    Counts counts;

    if (!measure)
    {
        if (!decodeBuffer(input, scratch, counts))
            return 1;

        printCounts(storage.length, counts);
        return 0;
    }

    // Untimed warm-up primes reusable decompression/StringTable scratch storage.
    Counts warmCounts;
    if (!decodeBuffer(input, scratch, warmCounts))
        return 1;

    StopWatch stopwatch = StopWatch(AutoStart.yes);
    if (!decodeBuffer(input, scratch, counts))
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
