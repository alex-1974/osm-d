/**
 * Bounded block-parallel whole-buffer PBF summary reader.
 *
 * Framing remains serial. OSMData jobs are collected into a fixed-capacity
 * batch and decoded in parallel with worker-local reusable scratch. No
 * semantic element view crosses the parallel boundary.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-02
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.parallel_reader;

import osm.io.pbf.blob : BlobView, decodeBlob;
import osm.io.pbf.blob_header : BlobKind;
import osm.io.pbf.decompress : BlobPayloadView;
import osm.io.pbf.dense_nodes : DenseNodeView;
import osm.io.pbf.error : PbfStatus;
import osm.io.pbf.features :
    HeaderFeatureAssessment,
    HeaderFeatureSupport,
    validateRequiredFeatures;
import osm.io.pbf.framing :
    FileBlockView,
    FrameReadResult,
    readFileBlock;
import osm.io.pbf.header_block : HeaderBlockView, decodeHeaderBlock;
import pbfNode = osm.io.pbf.node;
import osm.io.pbf.reader :
    PbfReadError,
    PbfReadStatus,
    PbfReadSummary,
    PbfReaderWorkspace,
    decodeDataBlock,
    decodeReaderBlobPayload,
    fromPbfFailure,
    readerFailure;
import osm.io.pbf.relation : RelationView;
import osm.io.pbf.way : WayView;
import osm.wire.cursor : WireCursor;

import std.parallelism : TaskPool, totalCPUs;
import std.range : iota;

/** Resource choices for PbfParallelReader. */
struct PbfParallelReadOptions
{
    /// Total decode lanes including the caller; zero selects available CPUs.
    size_t workerCount;
    /// Maximum OSMData jobs held in one batch; zero selects workerCount.
    size_t queueCapacity;
}

/**
 * Whole-buffer PBF reader for block-parallel validated summary decoding.
 *
 * PbfReader remains the ordered consumer-sink API. This type publishes only
 * aggregate value counters and never lets borrowed semantic views escape a
 * decode lane.
 */
struct PbfParallelReader
{
    /**
     * Validate/decode one complete already-loaded PBF and aggregate counts.
     *
     * The complete input must remain alive for this call. Jobs borrow Blob
     * slices from it. Zero-valued options select CPU-count/one-batch-per-lane
     * defaults.
     *
     * Returns true on complete success. On PBF failure, summary is reset and
     * status identifies the earliest failing file block.
     */
    bool readSummary(
        scope const(ubyte)[] input,
        PbfParallelReadOptions options,
        out PbfReadSummary summary,
        out PbfReadStatus status)
        @trusted
    {
        summary = PbfReadSummary.init;
        status = PbfReadStatus.init;

        auto cursor = WireCursor(input);
        ulong sequence;

        PbfReaderWorkspace headerWorkspace;
        if (!decodeLeadingHeader(
                input,
                cursor,
                sequence,
                headerWorkspace,
                status))
        {
            return false;
        }

        summary.headerBlocks = 1;
        if (cursor.empty)
            return true;

        size_t workerCount = options.workerCount;
        if (workerCount == 0)
        {
            workerCount = cast(size_t)totalCPUs;
            if (workerCount == 0)
                workerCount = 1;
        }

        size_t batchCapacity = options.queueCapacity;
        if (batchCapacity == 0)
            batchCapacity = workerCount;

        auto jobs = new PbfSummaryJob[batchCapacity];
        auto results = new PbfSummaryResult[batchCapacity];
        auto workspaces = new PbfReaderWorkspace[workerCount];

        TaskPool pool;
        if (workerCount > 1)
            pool = new TaskPool(workerCount - 1);
        scope(exit)
        {
            if (pool !is null)
                pool.finish(true);
        }

        while (true)
        {
            size_t jobCount;
            bool reachedEnd;
            bool hasProducerFailure;
            PbfReadStatus producerFailure;

            while (jobCount < batchCapacity)
            {
                const blockOffset = cursor.offset;
                FileBlockView fileBlock;
                PbfStatus pbfStatus;

                const frameResult =
                    readFileBlock(cursor, sequence, fileBlock, pbfStatus);

                final switch (frameResult)
                {
                    case FrameReadResult.endOfInput:
                        reachedEnd = true;
                        break;

                    case FrameReadResult.error:
                        producerFailure = fromPbfFailure(
                            sequence,
                            blockOffset,
                            pbfStatus);
                        hasProducerFailure = true;
                        break;

                    case FrameReadResult.block:
                        final switch (fileBlock.header.kind)
                        {
                            case BlobKind.osmData:
                                jobs[jobCount++] = PbfSummaryJob(
                                    fileBlock.sequence,
                                    fileBlock.offset,
                                    fileBlock.blob);
                                ++sequence;
                                continue;

                            case BlobKind.osmHeader:
                                producerFailure = readerFailure(
                                    PbfReadError.duplicateHeader,
                                    sequence,
                                    fileBlock.offset);
                                hasProducerFailure = true;
                                break;

                            case BlobKind.unknown:
                                producerFailure = readerFailure(
                                    PbfReadError.unsupportedBlockType,
                                    sequence,
                                    fileBlock.offset);
                                hasProducerFailure = true;
                                break;
                        }
                        break;
                }
                break;
            }

            if (jobCount != 0)
            {
                if (pool is null)
                {
                    foreach (i; 0 .. jobCount)
                        results[i] = decodeJob(jobs[i], workspaces[0]);
                }
                else
                {
                    foreach (i; pool.parallel(iota(jobCount), 1))
                    {
                        results[i] = decodeJob(
                            jobs[i],
                            workspaces[pool.workerIndex]);
                    }
                }

                foreach (i; 0 .. jobCount)
                {
                    if (!results[i].status.ok)
                    {
                        summary = PbfReadSummary.init;
                        status = results[i].status;
                        return false;
                    }

                    addSummary(summary, results[i].summary);
                    jobs[i] = PbfSummaryJob.init;
                    results[i] = PbfSummaryResult.init;
                }
            }

            if (hasProducerFailure)
            {
                summary = PbfReadSummary.init;
                status = producerFailure;
                return false;
            }

            if (reachedEnd)
                break;
        }

        status = PbfReadStatus.init;
        return true;
    }
}

private struct PbfSummaryJob
{
    ulong sequence;
    size_t fileBlockOffset;
    const(ubyte)[] blob;
}

private struct PbfSummaryResult
{
    PbfReadSummary summary;
    PbfReadStatus status;
}

private struct PbfSummarySink
{
    void putDenseNodeScalars(long, long, long) @safe nothrow @nogc {}
    void put(scope ref DenseNodeView) @safe nothrow @nogc {}
    void put(scope ref pbfNode.NodeView) @safe nothrow @nogc {}
    void put(scope ref WayView) @safe nothrow @nogc {}
    void put(scope ref RelationView) @safe nothrow @nogc {}
}

private PbfSummaryResult decodeJob(
    PbfSummaryJob job,
    ref PbfReaderWorkspace workspace)
{
    PbfSummaryResult result;
    PbfStatus pbfStatus;

    BlobView blob;
    if (!decodeBlob(job.blob, blob, pbfStatus))
    {
        result.status = fromPbfFailure(
            job.sequence,
            job.fileBlockOffset,
            pbfStatus);
        return result;
    }

    BlobPayloadView payload;
    if (!decodeReaderBlobPayload(
            blob,
            workspace,
            payload,
            pbfStatus))
    {
        result.status = fromPbfFailure(
            job.sequence,
            job.fileBlockOffset,
            pbfStatus);
        return result;
    }

    PbfSummarySink sink;
    if (!decodeDataBlock(
            payload.bytes,
            workspace,
            sink,
            result.summary,
            job.sequence,
            job.fileBlockOffset,
            result.status))
    {
        result.summary = PbfReadSummary.init;
        return result;
    }

    result.status = PbfReadStatus.init;
    return result;
}

private bool decodeLeadingHeader(
    scope const(ubyte)[] input,
    ref WireCursor cursor,
    ref ulong sequence,
    ref PbfReaderWorkspace workspace,
    out PbfReadStatus readStatus)
{
    const blockOffset = cursor.offset;
    FileBlockView fileBlock;
    PbfStatus pbfStatus;

    const frameResult =
        readFileBlock(cursor, sequence, fileBlock, pbfStatus);

    final switch (frameResult)
    {
        case FrameReadResult.endOfInput:
            readStatus = readerFailure(
                PbfReadError.missingHeader,
                sequence,
                input.length);
            return false;

        case FrameReadResult.error:
            readStatus = fromPbfFailure(
                sequence,
                blockOffset,
                pbfStatus);
            return false;

        case FrameReadResult.block:
            final switch (fileBlock.header.kind)
            {
                case BlobKind.osmData:
                    readStatus = readerFailure(
                        PbfReadError.dataBeforeHeader,
                        sequence,
                        fileBlock.offset);
                    return false;

                case BlobKind.unknown:
                    readStatus = readerFailure(
                        PbfReadError.unsupportedBlockType,
                        sequence,
                        fileBlock.offset);
                    return false;

                case BlobKind.osmHeader:
                    break;
            }

            BlobView blob;
            if (!decodeBlob(fileBlock.blob, blob, pbfStatus))
            {
                readStatus = fromPbfFailure(
                    sequence,
                    fileBlock.offset,
                    pbfStatus);
                return false;
            }

            BlobPayloadView payload;
            if (!decodeReaderBlobPayload(
                    blob,
                    workspace,
                    payload,
                    pbfStatus))
            {
                readStatus = fromPbfFailure(
                    sequence,
                    fileBlock.offset,
                    pbfStatus);
                return false;
            }

            HeaderBlockView header;
            if (!decodeHeaderBlock(payload.bytes, header, pbfStatus))
            {
                readStatus = fromPbfFailure(
                    sequence,
                    fileBlock.offset,
                    pbfStatus);
                return false;
            }

            HeaderFeatureAssessment assessment;
            if (!validateRequiredFeatures(
                    header,
                    HeaderFeatureSupport.allKnown(),
                    assessment,
                    pbfStatus))
            {
                readStatus = fromPbfFailure(
                    sequence,
                    fileBlock.offset,
                    pbfStatus);
                return false;
            }

            ++sequence;
            readStatus = PbfReadStatus.init;
            return true;
    }
}

private void addSummary(
    ref PbfReadSummary target,
    ref const PbfReadSummary source)
    @safe nothrow @nogc
{
    target.headerBlocks += source.headerBlocks;
    target.dataBlocks += source.dataBlocks;
    target.primitiveGroups += source.primitiveGroups;
    target.nodes += source.nodes;
    target.ways += source.ways;
    target.relations += source.relations;
    target.tags += source.tags;
}
