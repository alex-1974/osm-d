/**
 * Temporary qualification consumer for the PbfReader semantic node boundary.
 *
 * This source deliberately uses only the package-root semantic surface and a
 * templated callback so the exact same file builds against both the pre-change
 * baseline and the concrete-NodeView candidate.
 */
module osm.benchmark.parser.semantic_nodes_qualification;

import osm :
    PbfReadStatus,
    PbfReadSummary,
    PbfReader,
    PbfReaderWorkspace;

import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : stderr, writefln;

private struct ConsumerResult
{
    ulong checksum;
    size_t nodes;
    size_t tags;
    size_t metadataNodes;
}

pragma(inline, true)
private ulong mix(ulong state, ulong value) @safe pure nothrow @nogc
{
    return state ^
        (value + 0x9e37_79b9_7f4a_7c15UL + (state << 6) + (state >> 2));
}

pragma(inline, true)
private void mixBoundaryBytes(
    ref ulong checksum,
    scope const(ubyte)[] value)
    @safe pure nothrow @nogc
{
    checksum = mix(checksum, value.length);
    if (value.length != 0)
    {
        checksum = mix(checksum, value[0]);
        checksum = mix(checksum, value[$ - 1]);
    }
}

private struct NodeConsumer(bool TraverseTags)
{
    ConsumerResult result;

    void node(T)(scope ref T node) @safe nothrow @nogc
    {
        ++result.nodes;
        result.checksum = mix(result.checksum, cast(ulong)node.id);

        const location = node.location;
        result.checksum = mix(
            result.checksum,
            cast(ulong)location.latitudeNanodegrees);
        result.checksum = mix(
            result.checksum,
            cast(ulong)location.longitudeNanodegrees);

        const metadata = node.metadata;
        const hasMetadata =
            metadata.hasVersion ||
            metadata.hasTimestamp ||
            metadata.hasChangeset ||
            metadata.hasUserId ||
            metadata.hasUsername ||
            metadata.hasVisibility;

        if (hasMetadata)
        {
            ++result.metadataNodes;
            result.checksum = mix(result.checksum, metadata.hasVersion);
            result.checksum = mix(result.checksum, metadata.hasTimestamp);
            result.checksum = mix(result.checksum, metadata.hasChangeset);
            result.checksum = mix(result.checksum, metadata.hasUserId);
            result.checksum = mix(result.checksum, metadata.hasUsername);
            result.checksum = mix(result.checksum, metadata.hasVisibility);

            if (metadata.hasVersion)
                result.checksum = mix(
                    result.checksum,
                    cast(ulong)metadata.versionNumber);
            if (metadata.hasTimestamp)
                result.checksum = mix(
                    result.checksum,
                    cast(ulong)metadata.timestampMilliseconds);
            if (metadata.hasChangeset)
                result.checksum = mix(
                    result.checksum,
                    cast(ulong)metadata.changesetId);
            if (metadata.hasUserId)
                result.checksum = mix(
                    result.checksum,
                    cast(ulong)metadata.userId);
            if (metadata.hasUsername)
                mixBoundaryBytes(result.checksum, metadata.username);
            if (metadata.hasVisibility)
                result.checksum = mix(
                    result.checksum,
                    cast(ulong)metadata.visible);
        }

        static if (TraverseTags)
        {
            auto tags = node.tags;
            while (!tags.empty)
            {
                const tag = tags.front;
                mixBoundaryBytes(result.checksum, tag.key);
                mixBoundaryBytes(result.checksum, tag.value);
                ++result.tags;
                tags.popFront();
            }
        }
    }
}

private bool decode(bool TraverseTags)(
    const(ubyte)[] input,
    ref PbfReaderWorkspace workspace,
    out ConsumerResult result,
    out PbfReadSummary summary)
{
    PbfReader reader;
    NodeConsumer!TraverseTags consumer;
    PbfReadStatus status;

    if (!reader.read(input, workspace, consumer, summary, status))
    {
        stderr.writefln(
            "PBF read failed: error=%s block=%s block_offset=%s",
            status.error,
            status.blockSequence,
            status.blockOffset);
        return false;
    }

    result = consumer.result;
    return true;
}

private int run(bool TraverseTags)(const(ubyte)[] input)
{
    PbfReaderWorkspace workspace;

    ConsumerResult warmResult;
    PbfReadSummary warmSummary;
    if (!decode!TraverseTags(input, workspace, warmResult, warmSummary))
        return 1;

    ConsumerResult result;
    PbfReadSummary summary;

    StopWatch stopwatch = StopWatch(AutoStart.yes);
    if (!decode!TraverseTags(input, workspace, result, summary))
        return 1;
    stopwatch.stop();

    if (result != warmResult || summary != warmSummary)
    {
        stderr.writefln("non-deterministic semantic result after warm-up");
        return 1;
    }

    writefln("elapsed_ns=%s", stopwatch.peek.total!"nsecs");
    writefln("nodes=%s", result.nodes);
    writefln("tags_seen=%s", result.tags);
    writefln("metadata_nodes=%s", result.metadataNodes);
    writefln("checksum=%016x", result.checksum);
    writefln("summary_nodes=%s", summary.nodes);
    writefln("summary_tags=%s", summary.tags);
    return 0;
}

int main(string[] args)
{
    if (args.length != 3 ||
        (args[1] != "core" && args[1] != "tags"))
    {
        stderr.writefln("usage: %s core|tags FILE.osm.pbf", args[0]);
        return 2;
    }

    auto storage = cast(ubyte[])read(args[2]);
    const input = cast(const(ubyte)[])storage;

    if (args[1] == "core")
        return run!false(input);
    return run!true(input);
}
