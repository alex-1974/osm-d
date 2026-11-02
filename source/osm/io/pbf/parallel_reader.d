/**
 * Bounded block-parallel whole-buffer PBF summary reader.
 *
 * File framing and HeaderBlock validation remain serial. OSMData Blob jobs
 * borrow immutable slices from the caller's complete input and are decoded by
 * worker-local reusable PbfReaderWorkspace instances. No semantic element view
 * crosses the worker boundary; this first parallel API returns only owned
 * summary counters and status.
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
import osm.io.pbf.parallel_worker :
    ParallelBlockJob,
    ParallelDecodePool,
    isEarlier;
import osm.io.pbf.reader :
    PbfReadError,
    PbfReadStatus,
    PbfReadSummary,
    PbfReaderWorkspace,
    decodeReaderBlobPayload,
    fromPbfFailure,
    readerFailure;
import osm.wire.cursor : WireCursor;

import std.parallelism : totalCPUs;

/** Resource choices for PbfParallelReader. */
struct PbfParallelReadOptions
{
    /// Worker count; zero selects the CPU count available to the process.
    size_t workerCount;
    /// Queued OSMData jobs; zero selects one queued slot per worker.
    size_t queueCapacity;
}

/**
 * Whole-buffer PBF reader for parallel validated summary decoding.
 *
 * PbfReader remains the ordered consumer-sink API. This type parallelizes
 * block validation/decode only and publishes no borrowed element views.
 */
struct PbfParallelReader
{
    /**
     * Validate/decode one complete already-loaded PBF and aggregate counts.
     *
     * Natural defaults are selected by zero-valued options. All workers join
     * before return, so queued Blob slices never outlive input.
     *
     * Returns true on complete success. On PBF failure, summary is reset and
     * status identifies the earliest failing file block deterministically.
     *
     * Safety: the implementation stores slices of the scope-borrowed input in
     * a heap queue only while this call is active. Worker threads are joined
     * before return, input is immutable, and no borrowed decoded view escapes
     * a worker.
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

        size_t queueCapacity = options.queueCapacity;
        if (queueCapacity == 0)
            queueCapacity = workerCount;

        auto pool = new ParallelDecodePool(workerCount, queueCapacity);

        PbfReadStatus producerFailure;
        bool hasProducerFailure;

        try
        {
        producerLoop:
            while (true)
            {
                const blockOffset = cursor.offset;
                FileBlockView fileBlock;
                PbfStatus pbfStatus;

                const frameResult =
                    readFileBlock(cursor, sequence, fileBlock, pbfStatus);

                final switch (frameResult)
                {
                    case FrameReadResult.endOfInput:
                        break producerLoop;

                    case FrameReadResult.error:
                        producerFailure = fromPbfFailure(
                            sequence,
                            blockOffset,
                            pbfStatus);
                        hasProducerFailure = true;
                        break producerLoop;

                    case FrameReadResult.block:
                        final switch (fileBlock.header.kind)
                        {
                            case BlobKind.osmHeader:
                                producerFailure = readerFailure(
                                    PbfReadError.duplicateHeader,
                                    sequence,
                                    fileBlock.offset);
                                hasProducerFailure = true;
                                break producerLoop;

                            case BlobKind.osmData:
                                if (!pool.push(ParallelBlockJob(
                                        fileBlock.sequence,
                                        fileBlock.offset,
                                        fileBlock.blob)))
                                {
                                    break producerLoop;
                                }

                                ++sequence;
                                continue;

                            case BlobKind.unknown:
                                producerFailure = readerFailure(
                                    PbfReadError.unsupportedBlockType,
                                    sequence,
                                    fileBlock.offset);
                                hasProducerFailure = true;
                                break producerLoop;
                        }
                }
            }

            pool.close();
            pool.join();
        }
        catch (Throwable)
        {
            pool.close();
            throw;
        }

        PbfReadStatus workerFailure;
        const hasWorkerFailure = pool.earliestFailure(workerFailure);

        if (hasProducerFailure || hasWorkerFailure)
        {
            if (!hasProducerFailure ||
                (hasWorkerFailure &&
                 isEarlier(workerFailure, producerFailure)))
            {
                status = workerFailure;
            }
            else
            {
                status = producerFailure;
            }

            summary = PbfReadSummary.init;
            return false;
        }

        pool.reduce(summary);
        status = PbfReadStatus.init;
        return true;
    }
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
