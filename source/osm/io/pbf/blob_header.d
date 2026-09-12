/**
 * Zero-copy decoder for the OSMPBF `BlobHeader` protobuf message.
 *
 * The decoder extracts the three fields defined by `fileformat.proto` while
 * preserving the complete original serialized header as `BlobHeaderView.raw`.
 * Unknown non-group fields are skipped according to protobuf wire rules and
 * remain available in the raw bytes for future lossless handling. Deprecated
 * protobuf groups currently fail closed because the generic wire layer does not
 * yet implement bounded nested-group skipping. Singular known fields follow
 * normal protobuf parsing behavior: a later correctly encoded occurrence
 * replaces an earlier one.
 *
 * The protobuf `string` field `type` is exposed as bytes at this layer. UTF-8
 * policy is intentionally not imposed here because invalid-string handling is
 * still an explicit compatibility decision in `docs/SPEC_MATRIX.md`.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.blob_header;

import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.limits : maxSerializedBlobSize;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;
import osm.wire.varint : readVarint64;

/** Semantic classification of the standard OSMPBF file-block type strings. */
enum BlobKind : ubyte
{
    /// Any extension or otherwise unrecognized block type.
    unknown,
    /// Standard `OSMHeader` block containing a serialized `HeaderBlock`.
    osmHeader,
    /// Standard `OSMData` block containing a serialized `PrimitiveBlock`.
    osmData,
}

/**
 * Borrowed view of a decoded `BlobHeader` message.
 *
 * Every slice points into the caller-owned serialized header buffer. `raw`
 * includes unknown fields and duplicate occurrences exactly as received.
 */
struct BlobHeaderView
{
    /// Complete serialized BlobHeader bytes.
    const(ubyte)[] raw;
    /// Bytes from the last correctly encoded required `type` field.
    const(ubyte)[] type;
    /// Bytes from the last correctly encoded optional `indexdata` field.
    const(ubyte)[] indexData;
    /// Serialized length of the following `Blob` message.
    uint dataSize;
    /// Distinguishes an absent `indexdata` field from a present empty field.
    bool hasIndexData;

    /** Classify the standard OSM block types without allocating. */
    @property BlobKind kind() const @safe pure nothrow @nogc
    {
        return classifyBlobType(type);
    }

    /**
     * Returns whether the block type begins with the reserved underscore.
     *
     * `fileformat.proto` reserves type strings beginning with `_` for the
     * storage format itself.
     */
    @property bool reservedType() const @safe pure nothrow @nogc
    {
        return type.length != 0 && type[0] == cast(ubyte)'_';
    }
}

/**
 * Classify a BlobHeader type byte sequence.
 *
 * Params:
 *   type = Raw bytes stored in BlobHeader field 1.
 *
 * Returns:
 *   `BlobKind.osmHeader`, `BlobKind.osmData`, or `BlobKind.unknown`.
 */
BlobKind classifyBlobType(const(ubyte)[] type) @safe pure nothrow @nogc
{
    if (equalsAscii(type, "OSMHeader"))
        return BlobKind.osmHeader;
    if (equalsAscii(type, "OSMData"))
        return BlobKind.osmData;
    return BlobKind.unknown;
}

/**
 * Decode one complete serialized `BlobHeader` message.
 *
 * Unknown non-group protobuf fields are safely skipped but retained in
 * `header.raw`; unknown groups fail closed.
 * Known fields encoded with the wrong wire type are treated as unknown field
 * occurrences, matching protobuf's forward-compatible parsing model. At least
 * one correctly encoded occurrence of both required fields (`type` and
 * `datasize`) must be present.
 *
 * Params:
 *   input = Complete serialized BlobHeader message bytes.
 *   header = Receives the borrowed decoded view on success.
 *   status = Receives success or a precise PBF/wire failure.
 *
 * Returns:
 *   `true` when the complete header is structurally usable; `false` otherwise.
 *
 * Notes:
 *   No input bytes are copied and no memory is allocated. `header` must not
 *   outlive `input`.
 */
bool decodeBlobHeader(
    const(ubyte)[] input,
    out BlobHeaderView header,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto cursor = WireCursor(input);
    BlobHeaderView decoded;
    decoded.raw = input;

    bool sawType;
    bool sawDataSize;
    int decodedDataSize;
    size_t dataSizeOffset;

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            header = BlobHeaderView.init;
            status = PbfStatus.fromWire(wire);
            return false;
        }

        switch (field.number)
        {
            case 1:
                if (field.wireType == WireType.lengthDelimited)
                {
                    const(ubyte)[] value;
                    if (!readLengthDelimited(cursor, field.number, value, wire))
                    {
                        header = BlobHeaderView.init;
                        status = PbfStatus.fromWire(wire);
                        return false;
                    }
                    decoded.type = value;
                    sawType = true;
                }
                else if (!skipUnknownValue(cursor, field, status))
                {
                    header = BlobHeaderView.init;
                    return false;
                }
                break;

            case 2:
                if (field.wireType == WireType.lengthDelimited)
                {
                    const(ubyte)[] value;
                    if (!readLengthDelimited(cursor, field.number, value, wire))
                    {
                        header = BlobHeaderView.init;
                        status = PbfStatus.fromWire(wire);
                        return false;
                    }
                    decoded.indexData = value;
                    decoded.hasIndexData = true;
                }
                else if (!skipUnknownValue(cursor, field, status))
                {
                    header = BlobHeaderView.init;
                    return false;
                }
                break;

            case 3:
                if (field.wireType == WireType.varint)
                {
                    ulong value;
                    if (!readVarint64(cursor, value, wire))
                    {
                        header = BlobHeaderView.init;
                        status = PbfStatus.fromWire(wire);
                        return false;
                    }

                    // Proto2 int32 parsing keeps the low 32 bits of the
                    // decoded varint. Semantic framing checks are intentionally
                    // delayed until the complete message has been read so the
                    // normal singular-field "last one wins" rule is preserved.
                    decodedDataSize = cast(int)value;
                    dataSizeOffset = field.offset;
                    sawDataSize = true;
                }
                else if (!skipUnknownValue(cursor, field, status))
                {
                    header = BlobHeaderView.init;
                    return false;
                }
                break;

            default:
                if (!skipUnknownValue(cursor, field, status))
                {
                    header = BlobHeaderView.init;
                    return false;
                }
                break;
        }
    }

    if (!sawType)
    {
        header = BlobHeaderView.init;
        status = PbfStatus.failure(PbfError.missingBlobType, 0, 1);
        return false;
    }

    if (!sawDataSize)
    {
        header = BlobHeaderView.init;
        status = PbfStatus.failure(PbfError.missingBlobDataSize, input.length, 3);
        return false;
    }

    if (decodedDataSize < 0)
    {
        header = BlobHeaderView.init;
        status = PbfStatus.failure(
            PbfError.invalidBlobDataSize,
            dataSizeOffset,
            3);
        return false;
    }

    decoded.dataSize = cast(uint)decodedDataSize;
    if (decoded.dataSize > maxSerializedBlobSize)
    {
        header = BlobHeaderView.init;
        status = PbfStatus.failure(
            PbfError.blobDataTooLarge,
            dataSizeOffset,
            3);
        return false;
    }

    header = decoded;
    status = PbfStatus.init;
    return true;
}

private bool skipUnknownValue(
    ref WireCursor cursor,
    FieldHeader field,
    out PbfStatus status)
    @safe nothrow @nogc
{
    WireStatus wire;
    if (!skipFieldValue(cursor, field, wire))
    {
        status = PbfStatus.fromWire(wire);
        return false;
    }

    status = PbfStatus.init;
    return true;
}

private bool equalsAscii(const(ubyte)[] bytes, string ascii)
    @safe pure nothrow @nogc
{
    if (bytes.length != ascii.length)
        return false;

    foreach (i; 0 .. bytes.length)
    {
        if (bytes[i] != cast(ubyte)ascii[i])
            return false;
    }
    return true;
}

unittest
{
    // Canonical example BlobHeader from the OSM PBF format documentation:
    // type="OSMHeader", datasize=124.
    const(ubyte)[] bytes = [
        0x0a, 0x09,
        0x4f, 0x53, 0x4d, 0x48, 0x65, 0x61, 0x64, 0x65, 0x72,
        0x18, 0x7c,
    ];

    BlobHeaderView header;
    PbfStatus status;
    assert(decodeBlobHeader(bytes, header, status));
    assert(status.ok);
    assert(header.raw == bytes);
    assert(header.kind == BlobKind.osmHeader);
    assert(header.dataSize == 124);
    assert(!header.hasIndexData);
}

unittest
{
    // Unknown fixed32 field 4 is preserved in raw bytes and skipped
    // semantically. A later duplicate type field replaces the first one.
    const(ubyte)[] bytes = [
        0x0a, 0x01, 0x58,                   // type="X"
        0x25, 0xde, 0xad, 0xbe, 0xef,       // unknown field 4/fixed32
        0x0a, 0x07, 0x4f, 0x53, 0x4d, 0x44, 0x61, 0x74, 0x61,
        0x12, 0x00,                         // present empty indexdata
        0x18, 0x03,
    ];

    BlobHeaderView header;
    PbfStatus status;
    assert(decodeBlobHeader(bytes, header, status));
    assert(header.kind == BlobKind.osmData);
    assert(header.hasIndexData);
    assert(header.indexData.length == 0);
    assert(header.dataSize == 3);
    assert(header.raw == bytes);
}

unittest
{
    BlobHeaderView header;
    PbfStatus status;

    const(ubyte)[] onlySize = [0x18, 0x00];
    assert(!decodeBlobHeader(onlySize, header, status));
    assert(status.error == PbfError.missingBlobType);

    const(ubyte)[] onlyType = [0x0a, 0x01, 0x58];
    assert(!decodeBlobHeader(onlyType, header, status));
    assert(status.error == PbfError.missingBlobDataSize);

    // 32 MiB + 1 exceeds the defensive serialized-Blob limit.
    const(ubyte)[] tooLarge = [
        0x0a, 0x01, 0x58,
        0x18, 0x81, 0x80, 0x80, 0x10,
    ];
    assert(!decodeBlobHeader(tooLarge, header, status));
    assert(status.error == PbfError.blobDataTooLarge);

    // Proto2 int32 -1 is sign-extended and encoded as a ten-byte varint.
    const(ubyte)[] negativeSize = [
        0x0a, 0x01, 0x58,
        0x18,
        0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
    ];
    assert(!decodeBlobHeader(negativeSize, header, status));
    assert(status.error == PbfError.invalidBlobDataSize);

    // Singular protobuf fields use the last correctly encoded occurrence.
    const(ubyte)[] replacedNegativeSize = [
        0x0a, 0x01, 0x58,
        0x18,
        0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
        0x18, 0x03,
    ];
    assert(decodeBlobHeader(replacedNegativeSize, header, status));
    assert(header.dataSize == 3);
}
