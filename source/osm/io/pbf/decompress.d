/**
 * Bounded materialization of validated OSMPBF Blob payloads.
 *
 * Raw Blob payloads are returned zero-copy. Zlib payloads are decompressed into
 * caller-owned storage whose capacity is validated before calling zlib. The
 * zlib path uses `uncompress2`, allowing d-osm to enforce the declared
 * `raw_size` as a hard output bound and to reject trailing compressed bytes.
 * No GC allocation occurs in this module; streaming workers can therefore use
 * pooled per-worker buffers.
 *
 * LZMA, LZ4, and Zstandard fields are recognized by the Blob decoder but do
 * not yet have built-in backends. The deprecated bzip2 field receives a
 * distinct error so callers never confuse it with a future optional codec.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.decompress;

import etc.c.zlib : Z_BUF_ERROR, Z_OK, uncompress2;

import osm.io.pbf.blob : BlobView;
import osm.io.pbf.compression : BlobCodec;
import osm.io.pbf.error : PbfError, PbfStatus;

/** Ownership/lifetime source of bytes returned by `decodeBlobPayloadInto`. */
enum BlobPayloadStorage : ubyte
{
    /// Bytes borrow the serialized Blob's raw field.
    borrowedBlob,
    /// Bytes borrow the caller-provided output buffer.
    callerBuffer,
}

/** Borrowed view of validated uncompressed Blob payload bytes. */
struct BlobPayloadView
{
    /// Uncompressed protobuf payload bytes.
    const(ubyte)[] bytes;
    /// Storage backing `bytes`.
    BlobPayloadStorage storage;
    /// Representation from which the payload was obtained.
    BlobCodec sourceCodec;
}

/**
 * Return the caller-output capacity needed by `decodeBlobPayloadInto`.
 *
 * Raw payloads need no output buffer because they remain zero-copy. Every
 * compressed representation needs exactly its validated `raw_size` bytes when
 * a backend is available.
 */
size_t requiredOutputSize(const BlobView blob) @safe pure nothrow @nogc
{
    return blob.codec == BlobCodec.raw ? 0 : cast(size_t)blob.rawSize;
}

/**
 * Produce validated uncompressed payload bytes from a decoded Blob.
 *
 * Params:
 *   blob = Blob previously validated by `decodeBlob`.
 *   outputBuffer = Caller-owned decompression storage. For zlib it must contain
 *                  at least `blob.rawSize` bytes. It is ignored for raw data.
 *   payload = Receives a borrowed uncompressed view on success.
 *   status = Receives success or a decompression/backend failure.
 *
 * Returns:
 *   `true` for raw and successfully decoded zlib payloads; `false` otherwise.
 *
 * Safety:
 *   `payload.bytes` must not outlive the serialized Blob for raw payloads or
 *   `outputBuffer` for decompressed payloads.
 *
 * Notes:
 *   No D GC allocation occurs. zlib may use its own C allocator internally.
 */
bool decodeBlobPayloadInto(
    const BlobView blob,
    ubyte[] outputBuffer,
    out BlobPayloadView payload,
    out PbfStatus status)
    @safe nothrow @nogc
{
    payload = BlobPayloadView.init;
    status = PbfStatus.init;

    final switch (blob.codec)
    {
        case BlobCodec.none:
            status = PbfStatus.failure(PbfError.missingBlobPayload, 0);
            return false;

        case BlobCodec.raw:
            payload = BlobPayloadView(
                blob.payload,
                BlobPayloadStorage.borrowedBlob,
                BlobCodec.raw);
            return true;

        case BlobCodec.zlib:
            return decodeZlib(blob, outputBuffer, payload, status);

        case BlobCodec.obsoleteBzip2:
            status = PbfStatus.failure(
                PbfError.obsoleteBlobCompression,
                blob.payloadOffset,
                blob.payloadFieldNumber);
            return false;

        case BlobCodec.lzma:
        case BlobCodec.lz4:
        case BlobCodec.zstd:
            status = PbfStatus.failure(
                PbfError.unsupportedBlobCompression,
                blob.payloadOffset,
                blob.payloadFieldNumber);
            return false;
    }
}

private bool decodeZlib(
    const BlobView blob,
    ubyte[] outputBuffer,
    out BlobPayloadView payload,
    out PbfStatus status)
    @safe nothrow @nogc
{
    const expected = cast(size_t)blob.rawSize;
    if (outputBuffer.length < expected)
    {
        payload = BlobPayloadView.init;
        status = PbfStatus.failure(
            PbfError.outputBufferTooSmall,
            blob.payloadOffset,
            blob.payloadFieldNumber);
        return false;
    }

    size_t produced;
    size_t consumed;
    const rc = uncompressZlibBounded(
        blob.payload,
        expected,
        outputBuffer,
        produced,
        consumed);

    if (rc == Z_BUF_ERROR)
    {
        payload = BlobPayloadView.init;
        status = PbfStatus.failure(
            PbfError.decompressedSizeMismatch,
            blob.rawSizeOffset,
            2);
        return false;
    }

    if (rc != Z_OK)
    {
        payload = BlobPayloadView.init;
        status = PbfStatus.failure(
            PbfError.zlibDecompressionFailed,
            blob.payloadOffset,
            blob.payloadFieldNumber);
        return false;
    }

    if (produced != expected)
    {
        payload = BlobPayloadView.init;
        status = PbfStatus.failure(
            PbfError.decompressedSizeMismatch,
            blob.rawSizeOffset,
            2);
        return false;
    }

    if (consumed != blob.payload.length)
    {
        payload = BlobPayloadView.init;
        status = PbfStatus.failure(
            PbfError.trailingCompressedData,
            blob.payloadOffset,
            blob.payloadFieldNumber);
        return false;
    }

    payload = BlobPayloadView(
        outputBuffer[0 .. expected],
        BlobPayloadStorage.callerBuffer,
        BlobCodec.zlib);
    status = PbfStatus.init;
    return true;
}

private int uncompressZlibBounded(
    const(ubyte)[] source,
    size_t expectedOutputSize,
    ubyte[] outputBuffer,
    out size_t produced,
    out size_t consumed)
    @trusted nothrow @nogc
{
    size_t sourceLength = source.length;
    size_t destinationLength;
    ubyte[1] emptyOutputScratch = void;
    ubyte* destination;

    if (expectedOutputSize == 0)
    {
        // A one-byte scratch buffer lets zlib validate a legitimate empty
        // stream. Any actual output is detected below as a raw_size mismatch.
        destination = emptyOutputScratch.ptr;
        destinationLength = 1;
    }
    else
    {
        destination = outputBuffer.ptr;
        destinationLength = expectedOutputSize;
    }

    const rc = uncompress2(
        destination,
        &destinationLength,
        source.ptr,
        &sourceLength);

    produced = destinationLength;
    consumed = sourceLength;
    return rc;
}

unittest
{
    import osm.io.pbf.blob : decodeBlob;

    BlobView blob;
    BlobPayloadView payload;
    PbfStatus status;

    const(ubyte)[] raw = [
        0x0a, 0x05,
        0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ];
    assert(decodeBlob(raw, blob, status));
    ubyte[1] unused;
    assert(decodeBlobPayloadInto(blob, unused[], payload, status));
    assert(payload.storage == BlobPayloadStorage.borrowedBlob);
    assert(payload.bytes == cast(const(ubyte)[])"hello");

    const(ubyte)[] compressed = [
        0x10, 0x05,
        0x1a, 0x0d,
        0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9,
        0x07, 0x00, 0x06, 0x2c, 0x02, 0x15,
    ];
    assert(decodeBlob(compressed, blob, status));
    assert(requiredOutputSize(blob) == 5);
    ubyte[5] outBytes;
    assert(decodeBlobPayloadInto(blob, outBytes[], payload, status));
    assert(payload.storage == BlobPayloadStorage.callerBuffer);
    assert(payload.bytes == cast(const(ubyte)[])"hello");
}

unittest
{
    import osm.io.pbf.blob : decodeBlob;

    BlobView blob;
    BlobPayloadView payload;
    PbfStatus status;

    const(ubyte)[] compressed = [
        0x10, 0x05,
        0x1a, 0x0d,
        0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9,
        0x07, 0x00, 0x06, 0x2c, 0x02, 0x15,
    ];
    assert(decodeBlob(compressed, blob, status));
    ubyte[4] tooSmall;
    assert(!decodeBlobPayloadInto(blob, tooSmall[], payload, status));
    assert(status.error == PbfError.outputBufferTooSmall);

    // Declared raw_size is larger than the actual decoded stream.
    const(ubyte)[] wrongSize = [
        0x10, 0x06,
        0x1a, 0x0d,
        0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9,
        0x07, 0x00, 0x06, 0x2c, 0x02, 0x15,
    ];
    assert(decodeBlob(wrongSize, blob, status));
    ubyte[6] six;
    assert(!decodeBlobPayloadInto(blob, six[], payload, status));
    assert(status.error == PbfError.decompressedSizeMismatch);

    // Valid stream plus one trailing byte must not be silently ignored.
    const(ubyte)[] trailing = [
        0x10, 0x05,
        0x1a, 0x0e,
        0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9,
        0x07, 0x00, 0x06, 0x2c, 0x02, 0x15, 0xaa,
    ];
    assert(decodeBlob(trailing, blob, status));
    ubyte[5] five;
    assert(!decodeBlobPayloadInto(blob, five[], payload, status));
    assert(status.error == PbfError.trailingCompressedData);
}

unittest
{
    import osm.io.pbf.blob : decodeBlob;

    BlobView blob;
    BlobPayloadView payload;
    PbfStatus status;

    const(ubyte)[] lz4 = [
        0x10, 0x00,
        0x32, 0x00,
    ];
    assert(decodeBlob(lz4, blob, status));
    ubyte[] none;
    assert(!decodeBlobPayloadInto(blob, none, payload, status));
    assert(status.error == PbfError.unsupportedBlobCompression);

    const(ubyte)[] bzip2 = [
        0x10, 0x00,
        0x2a, 0x00,
    ];
    assert(decodeBlob(bzip2, blob, status));
    assert(!decodeBlobPayloadInto(blob, none, payload, status));
    assert(status.error == PbfError.obsoleteBlobCompression);
}
