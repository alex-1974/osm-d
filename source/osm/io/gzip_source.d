/**
 * Internal bounded GZIP ByteSource adapter for XML consumers.
 *
 * The adapter presents decoded bytes at absolute offsets so the existing dxml
 * ForwardRange bridge can re-read earlier positions. Forward reads keep one
 * decoder state and caller-owned Inflate workspace. A backward read restarts
 * decoding from compressed offset zero instead of retaining the whole decoded
 * document.
 *
 * This module is package-internal. Public replication diagnostics are mapped
 * by osm.replication.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-08
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.gzip_source;

import compression.core :
    DecodeError,
    DecodeLimits,
    DecodeStatus,
    ErrorCode,
    Result;
import compression.deflate :
    InflateWorkspace;
import compression.gzip :
    GzipState,
    decodeGzip;
import transport.source :
    ByteRange,
    ByteSource,
    ReadError,
    ReadFailure,
    ReadLimits,
    ReadResult,
    ReadValue,
    SourceInfo,
    valid;

package(osm):

enum GzipSourceFailure : ubyte
{
    none,
    transport,
    compression,
    compressedLimit,
    invalidOffset,
}

/** Last terminal adapter failure. */
struct GzipSourceStatus
{
    GzipSourceFailure failure = GzipSourceFailure.none;
    ReadError transportError = ReadError.none;
    DecodeError compressionError;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return failure == GzipSourceFailure.none;
    }
}

/**
 * Absolute-offset decoded view over one stable GZIP ByteSource.
 *
 * The normal path is strictly forward. Backward reads are supported by
 * resetting the decoder and replaying from compressed offset zero, which keeps
 * memory bounded while satisfying dxml ForwardRange.save semantics.
 */
final class GzipDecodedSource : ByteSource
{
private:
    ByteSource source;
    DecodeLimits limits;
    ulong maximumCompressedBytes;
    size_t readChunkSize;
    ubyte[] inputBuffer;
    ubyte[] discardBuffer;

    GzipState decoder;
    InflateWorkspace workspace;

    size_t inputBegin;
    size_t inputEnd;
    ulong compressedReadOffset;
    ulong decodedOffset;
    bool compressedEnd;
    bool decoderDone;

    GzipSourceStatus lastStatus;

public:
    this(
        ByteSource source,
        size_t compressedBufferSize,
        ulong maximumCompressedBytes,
        DecodeLimits limits) @safe
    {
        this.source = source;
        this.maximumCompressedBytes = maximumCompressedBytes;
        this.limits = limits;

        readChunkSize = compressedBufferSize == 0
            ? 64 * 1024
            : compressedBufferSize;

        // decodeGzip may retain a short unread suffix when it needs the next
        // chunk. Keep append capacity independent of the caller-selected
        // transport chunk size so even one-byte reads remain valid.
        const inputCapacity = readChunkSize < 64
            ? 64
            : readChunkSize;

        inputBuffer = new ubyte[inputCapacity];
        discardBuffer = new ubyte[64 * 1024];
        resetDecoder();
    }

    @property SourceInfo sourceInfo() const @safe
    {
        return SourceInfo(
            "gzip-decoded",
            "gzip",
            decoderDone,
            decoderDone ? decodedOffset : 0,
            true);
    }

    @property GzipSourceStatus status() const @safe pure nothrow @nogc
    {
        return lastStatus;
    }

    @property ulong compressedBytesRead() const @safe pure nothrow @nogc
    {
        return compressedReadOffset;
    }

    @property ulong decodedBytes() const @safe pure nothrow @nogc
    {
        return decodedOffset;
    }

    @property bool complete() const @safe pure nothrow @nogc
    {
        return decoderDone;
    }

    ReadResult read(
        ByteRange range,
        scope ubyte[] destination,
        ReadLimits readLimits = ReadLimits.init) @safe
    {
        if (!range.valid)
            return failure(ReadError.invalidRange);

        if (range.length > readLimits.maximumBytes)
            return failure(ReadError.limitExceeded);

        if (destination.length < range.length)
            return failure(ReadError.destinationTooSmall);

        auto result = readSome(
            range.offset,
            destination[0 .. range.length],
            ReadLimits(range.length));

        if (result.hasValue &&
            result.value.bytesRead == range.length)
        {
            return result;
        }

        if (result.hasValue)
            return failure(ReadError.invalidRange, result.value.bytesRead);

        return result;
    }

    ReadResult readSome(
        ulong offset,
        scope ubyte[] destination,
        ReadLimits readLimits = ReadLimits.init) @safe
    {
        if (destination.length > readLimits.maximumBytes)
            return failure(ReadError.limitExceeded);

        if (destination.length == 0)
            return failure(ReadError.endOfSource);

        if (!lastStatus.ok)
            return failure(ReadError.sourceFailure);

        if (offset < decodedOffset)
            resetDecoder();

        if (offset > decodedOffset)
        {
            if (!skipTo(offset))
                return mappedFailure();
        }

        if (decoderDone)
        {
            return offset == decodedOffset
                ? failure(ReadError.endOfSource)
                : failure(ReadError.invalidRange);
        }

        size_t written;
        while (written < destination.length)
        {
            auto step = drive(destination[written .. $]);
            decodedOffset += step.produced;
            written += step.produced;

            final switch (step.status)
            {
                case DecodeStatus.needInput:
                    // drive() resolves input starvation internally.
                    setCompressionFailure(
                        ErrorCode.invalidData,
                        decoder.totalInput);
                    return mappedFailure(written);

                case DecodeStatus.needOutput:
                    if (written == destination.length)
                        return success(written);
                    break;

                case DecodeStatus.done:
                    decoderDone = true;
                    return written == 0
                        ? failure(ReadError.endOfSource)
                        : success(written);

                case DecodeStatus.error:
                    if (lastStatus.ok)
                        setCompressionFailure(step.error);
                    return mappedFailure(written);
            }
        }

        return success(written);
    }

    /**
     * Ensure that the GZIP trailer/member sequence has been fully validated
     * after a successful semantic parse.
     *
     * false with status.ok means additional decoded bytes still exist; callers
     * should classify that as semantic trailing content rather than a codec
     * failure.
     */
    bool finishValidation() @safe
    {
        if (decoderDone)
            return true;

        auto step = drive(null);

        final switch (step.status)
        {
            case DecodeStatus.done:
                decoderDone = true;
                return true;

            case DecodeStatus.needOutput:
                return false;

            case DecodeStatus.error:
                if (lastStatus.ok)
                    setCompressionFailure(step.error);
                return false;

            case DecodeStatus.needInput:
                setCompressionFailure(
                    ErrorCode.invalidData,
                    decoder.totalInput);
                return false;
        }
    }

private:
    void resetDecoder() @safe
    {
        decoder.reset(limits, true);
        inputBegin = 0;
        inputEnd = 0;
        compressedReadOffset = 0;
        decodedOffset = 0;
        compressedEnd = false;
        decoderDone = false;
        lastStatus = GzipSourceStatus.init;
    }

    bool skipTo(ulong target) @safe
    {
        while (decodedOffset < target)
        {
            auto remaining = target - decodedOffset;
            size_t width = discardBuffer.length;
            if (remaining < width)
                width = cast(size_t) remaining;

            auto step = drive(discardBuffer[0 .. width]);
            decodedOffset += step.produced;

            final switch (step.status)
            {
                case DecodeStatus.needOutput:
                    break;

                case DecodeStatus.done:
                    decoderDone = true;
                    if (decodedOffset < target)
                    {
                        lastStatus.failure = GzipSourceFailure.invalidOffset;
                        return false;
                    }
                    break;

                case DecodeStatus.error:
                    if (lastStatus.ok)
                        setCompressionFailure(step.error);
                    return false;

                case DecodeStatus.needInput:
                    setCompressionFailure(
                        ErrorCode.invalidData,
                        decoder.totalInput);
                    return false;
            }

            if (decoderDone && decodedOffset < target)
            {
                lastStatus.failure = GzipSourceFailure.invalidOffset;
                return false;
            }
        }

        return true;
    }

    Result drive(scope ubyte[] output) @safe
    {
        while (true)
        {
            if (inputBegin == inputEnd && !compressedEnd)
            {
                if (!refillInput())
                    return Result.failure(
                        ErrorCode.invalidArgument);
            }

            auto step = decodeGzip(
                decoder,
                workspace,
                inputBuffer[inputBegin .. inputEnd],
                output,
                compressedEnd);

            inputBegin += step.consumed;

            if (step.status != DecodeStatus.needInput)
                return step;

            if (compressedEnd)
                return step;

            if (!refillInput())
                return Result.failure(
                    ErrorCode.invalidArgument,
                    step.consumed,
                    step.produced);
        }
    }

    bool refillInput() @safe
    {
        if (compressedEnd)
            return true;

        const remaining = inputEnd - inputBegin;
        if (remaining != 0 && inputBegin != 0)
        {
            foreach (i; 0 .. remaining)
                inputBuffer[i] = inputBuffer[inputBegin + i];
        }

        inputBegin = 0;
        inputEnd = remaining;

        if (inputEnd == inputBuffer.length)
        {
            setCompressionFailure(
                ErrorCode.invalidData,
                decoder.totalInput);
            return false;
        }

        size_t request = inputBuffer.length - inputEnd;
        if (request > readChunkSize)
            request = readChunkSize;

        if (maximumCompressedBytes != 0)
        {
            if (compressedReadOffset >= maximumCompressedBytes)
            {
                lastStatus.failure =
                    GzipSourceFailure.compressedLimit;
                return false;
            }

            const allowed =
                maximumCompressedBytes - compressedReadOffset;
            if (allowed < request)
                request = cast(size_t) allowed;

            if (request == 0)
            {
                lastStatus.failure =
                    GzipSourceFailure.compressedLimit;
                return false;
            }
        }

        auto read = source.readSome(
            compressedReadOffset,
            inputBuffer[inputEnd .. inputEnd + request],
            ReadLimits(request));

        if (read.hasError)
        {
            if (read.error.kind == ReadError.endOfSource)
            {
                compressedEnd = true;
                return true;
            }

            lastStatus.failure = GzipSourceFailure.transport;
            lastStatus.transportError = read.error.kind;
            return false;
        }

        if (read.value.bytesRead == 0)
        {
            lastStatus.failure = GzipSourceFailure.transport;
            lastStatus.transportError = ReadError.sourceFailure;
            return false;
        }

        inputEnd += read.value.bytesRead;
        compressedReadOffset += read.value.bytesRead;

        // transport-d guarantees that a short successful read is the final
        // available chunk.
        if (read.value.bytesRead < request)
            compressedEnd = true;

        return true;
    }

    void setCompressionFailure(
        DecodeError error) @safe pure nothrow @nogc
    {
        lastStatus.failure = GzipSourceFailure.compression;
        lastStatus.compressionError = error;
    }

    void setCompressionFailure(
        ErrorCode code,
        ulong offset) @safe pure nothrow @nogc
    {
        setCompressionFailure(DecodeError(code, offset));
    }

    ReadResult mappedFailure(size_t bytesRead = 0) const @safe
    {
        final switch (lastStatus.failure)
        {
            case GzipSourceFailure.compressedLimit:
                return failure(ReadError.limitExceeded, bytesRead);

            case GzipSourceFailure.invalidOffset:
                return failure(ReadError.invalidRange, bytesRead);

            case GzipSourceFailure.transport:
            case GzipSourceFailure.compression:
                return failure(ReadError.sourceFailure, bytesRead);

            case GzipSourceFailure.none:
                return failure(ReadError.sourceFailure, bytesRead);
        }
    }
}

private ReadResult success(size_t bytes) @safe
{
    return ReadResult.success(ReadValue(bytes));
}

private ReadResult failure(
    ReadError error,
    size_t bytes = 0) @safe
{
    return ReadResult.failure(ReadFailure(error, bytes));
}
