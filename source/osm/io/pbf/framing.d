/**
 * Zero-copy framing of OSMPBF file blocks.
 *
 * A PBF file is a sequence of a four-byte network-order BlobHeader length,
 * the serialized BlobHeader itself, and the serialized Blob body whose length
 * is given by `BlobHeader.datasize`. This module extracts one complete block
 * from a bounded `WireCursor` without allocation or decompression.
 *
 * Parsing is transactional with respect to the caller's cursor: on any error
 * the supplied cursor remains unchanged. A clean empty cursor is reported as
 * end-of-input, whereas a trailing one-to-three-byte prefix is corruption.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.framing;

import osm.io.pbf.blob_header : BlobHeaderView, BlobKind, decodeBlobHeader;
import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.limits : maxBlobHeaderSize;
import osm.wire.cursor : WireCursor;

/** Result category returned by `readFileBlock`. */
enum FrameReadResult : ubyte
{
    /// A complete file block was decoded.
    block,
    /// The cursor was already empty at a block boundary.
    endOfInput,
    /// Malformed, oversized, or truncated framing was encountered.
    error,
}

/**
 * Borrowed view of one complete serialized PBF file block.
 *
 * `header` and `blob` point into the caller-owned file buffer. `blob` is still
 * the serialized `Blob` protobuf message; this framing layer neither parses
 * nor decompresses it.
 */
struct FileBlockView
{
    /// Monotonic sequence number supplied by the caller/pipeline.
    ulong sequence;
    /// Byte offset at which this block's four-byte length prefix begins.
    size_t offset;
    /// Decoded BlobHeader view.
    BlobHeaderView header;
    /// Complete serialized Blob message bytes.
    const(ubyte)[] blob;

    /** Total encoded byte length of this block including the four-byte prefix. */
    @property size_t encodedSize() const @safe pure nothrow @nogc
    {
        return 4 + header.raw.length + blob.length;
    }
}

/**
 * Decode one complete PBF file block from `cursor`.
 *
 * Params:
 *   cursor = Cursor over the remaining PBF file bytes.
 *   sequence = Sequence number to attach to the returned block view.
 *   block = Receives the borrowed block view on success.
 *   status = Receives success or the framing failure.
 *
 * Returns:
 *   `FrameReadResult.block` for one decoded block,
 *   `FrameReadResult.endOfInput` when called exactly at clean EOF, or
 *   `FrameReadResult.error` for malformed/truncated input.
 *
 * Notes:
 *   On error the caller's `cursor` is not advanced. On success it advances by
 *   exactly `block.encodedSize` bytes. No memory is allocated.
 */
FrameReadResult readFileBlock(
    ref WireCursor cursor,
    ulong sequence,
    out FileBlockView block,
    out PbfStatus status)
    @safe nothrow @nogc
{
    block = FileBlockView.init;
    status = PbfStatus.init;

    if (cursor.empty)
        return FrameReadResult.endOfInput;

    const frameOffset = cursor.offset;
    auto probe = cursor;

    const(ubyte)[] lengthBytes;
    if (!probe.take(4, lengthBytes))
    {
        status = PbfStatus.failure(PbfError.truncatedHeaderLength, frameOffset);
        return FrameReadResult.error;
    }

    const uint headerLength = decodeNetworkU32(lengthBytes);
    if (headerLength >= maxBlobHeaderSize)
    {
        status = PbfStatus.failure(PbfError.blobHeaderTooLarge, frameOffset);
        return FrameReadResult.error;
    }

    const headerOffset = probe.offset;
    const(ubyte)[] headerBytes;
    if (!probe.take(cast(size_t)headerLength, headerBytes))
    {
        status = PbfStatus.failure(PbfError.truncatedBlobHeader, headerOffset);
        return FrameReadResult.error;
    }

    BlobHeaderView header;
    PbfStatus headerStatus;
    if (!decodeBlobHeader(headerBytes, header, headerStatus))
    {
        status = translateHeaderStatus(headerStatus, headerOffset);
        return FrameReadResult.error;
    }

    const blobOffset = probe.offset;
    const(ubyte)[] blobBytes;
    if (!probe.take(cast(size_t)header.dataSize, blobBytes))
    {
        status = PbfStatus.failure(PbfError.truncatedBlobData, blobOffset);
        return FrameReadResult.error;
    }

    block = FileBlockView(sequence, frameOffset, header, blobBytes);
    cursor = probe;
    status = PbfStatus.init;
    return FrameReadResult.block;
}

private uint decodeNetworkU32(const(ubyte)[] bytes) @safe pure nothrow @nogc
in (bytes.length == 4)
{
    return (cast(uint)bytes[0] << 24)
         | (cast(uint)bytes[1] << 16)
         | (cast(uint)bytes[2] << 8)
         | cast(uint)bytes[3];
}

private PbfStatus translateHeaderStatus(PbfStatus status, size_t headerOffset)
    @safe pure nothrow @nogc
{
    status.offset += headerOffset;
    return status;
}

unittest
{
    // Header: type="OSMData", datasize=3.
    const(ubyte)[] frame = [
        0x00, 0x00, 0x00, 0x0b,
        0x0a, 0x07, 0x4f, 0x53, 0x4d, 0x44, 0x61, 0x74, 0x61,
        0x18, 0x03,
        0xaa, 0xbb, 0xcc,
    ];

    auto cursor = WireCursor(frame);
    FileBlockView block;
    PbfStatus status;

    assert(readFileBlock(cursor, 7, block, status) == FrameReadResult.block);
    assert(status.ok);
    assert(block.sequence == 7);
    assert(block.offset == 0);
    assert(block.header.dataSize == 3);
    assert(block.encodedSize == frame.length);
    const(ubyte)[] expectedBlob = [0xaa, 0xbb, 0xcc];
    assert(block.blob == expectedBlob);
    assert(cursor.empty);

    assert(readFileBlock(cursor, 8, block, status) == FrameReadResult.endOfInput);
    assert(status.ok);
}

unittest
{
    FileBlockView block;
    PbfStatus status;

    // A partial four-byte prefix is corruption and must not consume input.
    const(ubyte)[] shortPrefix = [0x00, 0x00, 0x00];
    auto a = WireCursor(shortPrefix);
    assert(readFileBlock(a, 0, block, status) == FrameReadResult.error);
    assert(status.error == PbfError.truncatedHeaderLength);
    assert(a.offset == 0);

    // Exactly 64 KiB is invalid because BlobHeader must be smaller than it.
    const(ubyte)[] hugeHeader = [0x00, 0x01, 0x00, 0x00];
    auto b = WireCursor(hugeHeader);
    assert(readFileBlock(b, 0, block, status) == FrameReadResult.error);
    assert(status.error == PbfError.blobHeaderTooLarge);
    assert(b.offset == 0);
}

unittest
{
    FileBlockView block;
    PbfStatus status;

    // Prefix says 11 header bytes, but only two follow.
    const(ubyte)[] truncatedHeader = [
        0x00, 0x00, 0x00, 0x0b,
        0x0a, 0x07,
    ];
    auto a = WireCursor(truncatedHeader);
    assert(readFileBlock(a, 0, block, status) == FrameReadResult.error);
    assert(status.error == PbfError.truncatedBlobHeader);
    assert(a.offset == 0);

    // Complete header requests three Blob bytes but only two are present.
    const(ubyte)[] truncatedBlob = [
        0x00, 0x00, 0x00, 0x0b,
        0x0a, 0x07, 0x4f, 0x53, 0x4d, 0x44, 0x61, 0x74, 0x61,
        0x18, 0x03,
        0xaa, 0xbb,
    ];
    auto b = WireCursor(truncatedBlob);
    assert(readFileBlock(b, 0, block, status) == FrameReadResult.error);
    assert(status.error == PbfError.truncatedBlobData);
    assert(b.offset == 0);

    // A structurally complete but semantically invalid BlobHeader is also
    // transactional with respect to the outer file cursor.
    const(ubyte)[] missingType = [
        0x00, 0x00, 0x00, 0x02,
        0x18, 0x00,
    ];
    auto c = WireCursor(missingType);
    assert(readFileBlock(c, 0, block, status) == FrameReadResult.error);
    assert(status.error == PbfError.missingBlobType);
    assert(c.offset == 0);
}

unittest
{
    // Unknown extension block types remain representable rather than being
    // silently discarded by the framing layer.
    const(ubyte)[] frame = [
        0x00, 0x00, 0x00, 0x05,
        0x0a, 0x01, 0x58,
        0x18, 0x00,
    ];

    auto cursor = WireCursor(frame);
    FileBlockView block;
    PbfStatus status;
    assert(readFileBlock(cursor, 0, block, status) == FrameReadResult.block);
    assert(block.header.kind == BlobKind.unknown);
    assert(block.blob.length == 0);
}
