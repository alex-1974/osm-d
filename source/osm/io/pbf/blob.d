/**
 * Zero-copy decoder and semantic validation for OSMPBF `Blob` messages.
 *
 * `decodeBlob` parses the storage-level protobuf message without decompressing
 * its payload. Known payload fields remain borrowed slices into the serialized
 * Blob, while the complete original message is retained as `BlobView.raw`.
 * Unknown non-group fields are skipped but therefore remain available in
 * `raw` for later lossless handling.
 *
 * The decoder deliberately rejects more than one correctly encoded `data`
 * oneof occurrence. Generic protobuf runtimes normally let the final oneof
 * member win, but silently shadowing an earlier payload would violate d-osm's
 * no-silent-loss contract. Raw bytes are still available to lower-level raw
 * handling; the validated Blob representation requires one unambiguous payload.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.blob;

import osm.io.pbf.compression : BlobCodec, blobPayloadFieldNumber, isCompressed;
import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.limits : maxUncompressedBlobSize;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;
import osm.wire.varint : readVarint64;

/** Borrowed validated view of one serialized OSMPBF `Blob` message. */
struct BlobView
{
    /// Complete serialized Blob bytes, including unknown fields.
    const(ubyte)[] raw;
    /// Active, unambiguous payload representation.
    BlobCodec codec;
    /// Borrowed bytes from the active payload field.
    const(ubyte)[] payload;
    /// Validated uncompressed size in bytes.
    uint rawSize;
    /// Whether protobuf field 2 (`raw_size`) was explicitly present.
    bool hasRawSize;
    /// Offset of the active payload field key inside `raw`.
    size_t payloadOffset;
    /// Offset of the final correctly encoded `raw_size` field key.
    size_t rawSizeOffset;

    /** Return the protobuf field number of the active payload. */
    @property uint payloadFieldNumber() const @safe pure nothrow @nogc
    {
        return blobPayloadFieldNumber(codec);
    }

    /** Return whether the active representation is compressed. */
    @property bool compressed() const @safe pure nothrow @nogc
    {
        return isCompressed(codec);
    }
}

/**
 * Decode and validate one complete serialized OSMPBF `Blob` message.
 *
 * Validation performed here is independent of any decompressor backend:
 * exactly one known data payload must be present; `raw_size`, when present,
 * must be non-negative and below the format's exclusive 32 MiB hard limit;
 * compressed payloads require `raw_size`; and raw payloads must agree with an
 * explicitly supplied `raw_size`.
 *
 * Params:
 *   input = Complete serialized Blob message bytes.
 *   blob = Receives the borrowed validated view on success.
 *   status = Receives success or a precise PBF/wire failure.
 *
 * Returns:
 *   `true` when the Blob is structurally and semantically safe to process;
 *   `false` otherwise.
 *
 * Notes:
 *   No memory is allocated. `blob` must not outlive `input`.
 */
bool decodeBlob(
    const(ubyte)[] input,
    out BlobView blob,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto cursor = WireCursor(input);
    BlobView decoded;
    decoded.raw = input;

    uint payloadOccurrences;
    bool sawRawSize;
    int decodedRawSize;
    size_t rawSizeOffset;

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            blob = BlobView.init;
            status = PbfStatus.fromBlobWire(wire);
            return false;
        }

        switch (field.number)
        {
            case 1:
                if (!decodePayloadField(
                    cursor,
                    field,
                    BlobCodec.raw,
                    decoded,
                    payloadOccurrences,
                    status))
                {
                    blob = BlobView.init;
                    return false;
                }
                break;

            case 2:
                if (field.wireType == WireType.varint)
                {
                    ulong value;
                    if (!readVarint64(cursor, value, wire))
                    {
                        blob = BlobView.init;
                        status = PbfStatus.fromBlobWire(wire);
                        return false;
                    }

                    // Proto2 int32 uses the low 32 bits after varint decoding.
                    // Delay semantic validation so a later singular occurrence
                    // follows protobuf's normal "last one wins" rule.
                    decodedRawSize = cast(int)value;
                    rawSizeOffset = field.offset;
                    sawRawSize = true;
                }
                else if (!skipUnknownValue(cursor, field, status))
                {
                    blob = BlobView.init;
                    return false;
                }
                break;

            case 3:
                if (!decodePayloadField(
                    cursor,
                    field,
                    BlobCodec.zlib,
                    decoded,
                    payloadOccurrences,
                    status))
                {
                    blob = BlobView.init;
                    return false;
                }
                break;

            case 4:
                if (!decodePayloadField(
                    cursor,
                    field,
                    BlobCodec.lzma,
                    decoded,
                    payloadOccurrences,
                    status))
                {
                    blob = BlobView.init;
                    return false;
                }
                break;

            case 5:
                if (!decodePayloadField(
                    cursor,
                    field,
                    BlobCodec.obsoleteBzip2,
                    decoded,
                    payloadOccurrences,
                    status))
                {
                    blob = BlobView.init;
                    return false;
                }
                break;

            case 6:
                if (!decodePayloadField(
                    cursor,
                    field,
                    BlobCodec.lz4,
                    decoded,
                    payloadOccurrences,
                    status))
                {
                    blob = BlobView.init;
                    return false;
                }
                break;

            case 7:
                if (!decodePayloadField(
                    cursor,
                    field,
                    BlobCodec.zstd,
                    decoded,
                    payloadOccurrences,
                    status))
                {
                    blob = BlobView.init;
                    return false;
                }
                break;

            default:
                if (!skipUnknownValue(cursor, field, status))
                {
                    blob = BlobView.init;
                    return false;
                }
                break;
        }
    }

    if (payloadOccurrences == 0)
    {
        blob = BlobView.init;
        status = PbfStatus.failure(PbfError.missingBlobPayload, 0);
        return false;
    }

    if (sawRawSize)
    {
        if (decodedRawSize < 0)
        {
            blob = BlobView.init;
            status = PbfStatus.failure(PbfError.invalidBlobRawSize, rawSizeOffset, 2);
            return false;
        }

        if (cast(uint)decodedRawSize >= maxUncompressedBlobSize)
        {
            blob = BlobView.init;
            status = PbfStatus.failure(
                PbfError.uncompressedBlobTooLarge,
                rawSizeOffset,
                2);
            return false;
        }

        decoded.rawSize = cast(uint)decodedRawSize;
        decoded.rawSizeOffset = rawSizeOffset;
        decoded.hasRawSize = true;
    }

    if (decoded.codec == BlobCodec.raw)
    {
        if (decoded.payload.length >= maxUncompressedBlobSize)
        {
            blob = BlobView.init;
            status = PbfStatus.failure(
                PbfError.uncompressedBlobTooLarge,
                decoded.payloadOffset,
                1);
            return false;
        }

        if (decoded.hasRawSize && decoded.rawSize != decoded.payload.length)
        {
            blob = BlobView.init;
            status = PbfStatus.failure(
                PbfError.blobRawSizeMismatch,
                decoded.rawSizeOffset,
                2);
            return false;
        }

        if (!decoded.hasRawSize)
            decoded.rawSize = cast(uint)decoded.payload.length;
    }
    else if (!decoded.hasRawSize)
    {
        blob = BlobView.init;
        status = PbfStatus.failure(
            PbfError.missingBlobRawSize,
            decoded.payloadOffset,
            decoded.payloadFieldNumber);
        return false;
    }

    blob = decoded;
    status = PbfStatus.init;
    return true;
}

private bool decodePayloadField(
    ref WireCursor cursor,
    FieldHeader field,
    BlobCodec codec,
    ref BlobView decoded,
    ref uint payloadOccurrences,
    out PbfStatus status)
    @safe nothrow @nogc
{
    if (field.wireType != WireType.lengthDelimited)
        return skipUnknownValue(cursor, field, status);

    WireStatus wire;
    const(ubyte)[] payload;
    if (!readLengthDelimited(cursor, field.number, payload, wire))
    {
        status = PbfStatus.fromBlobWire(wire);
        return false;
    }

    ++payloadOccurrences;
    if (payloadOccurrences > 1)
    {
        status = PbfStatus.failure(
            PbfError.multipleBlobPayloads,
            field.offset,
            field.number);
        return false;
    }

    decoded.codec = codec;
    decoded.payload = payload;
    decoded.payloadOffset = field.offset;
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
        status = PbfStatus.fromBlobWire(wire);
        return false;
    }

    status = PbfStatus.init;
    return true;
}

unittest
{
    BlobView blob;
    PbfStatus status;

    // raw="hello", no raw_size. Raw payloads may omit field 2.
    const(ubyte)[] raw = [
        0x0a, 0x05,
        0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ];
    assert(decodeBlob(raw, blob, status));
    assert(status.ok);
    assert(blob.codec == BlobCodec.raw);
    assert(blob.raw == raw);
    assert(blob.rawSize == 5);
    assert(!blob.hasRawSize);

    // raw_size=5, zlib_data contains zlib("hello").
    const(ubyte)[] compressed = [
        0x10, 0x05,
        0x1a, 0x0d,
        0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9,
        0x07, 0x00, 0x06, 0x2c, 0x02, 0x15,
    ];
    assert(decodeBlob(compressed, blob, status));
    assert(blob.codec == BlobCodec.zlib);
    assert(blob.hasRawSize && blob.rawSize == 5);
}

unittest
{
    BlobView blob;
    PbfStatus status;

    // A validated Blob refuses to silently apply protobuf oneof last-wins.
    const(ubyte)[] multiple = [
        0x0a, 0x01, 0x41,
        0x10, 0x01,
        0x1a, 0x01, 0x42,
    ];
    assert(!decodeBlob(multiple, blob, status));
    assert(status.error == PbfError.multipleBlobPayloads);
    assert(status.fieldNumber == 3);

    const(ubyte)[] missingPayload = [0x10, 0x01];
    assert(!decodeBlob(missingPayload, blob, status));
    assert(status.error == PbfError.missingBlobPayload);

    const(ubyte)[] compressedWithoutSize = [0x1a, 0x01, 0x00];
    assert(!decodeBlob(compressedWithoutSize, blob, status));
    assert(status.error == PbfError.missingBlobRawSize);

    const(ubyte)[] rawSizeMismatch = [
        0x0a, 0x01, 0x41,
        0x10, 0x02,
    ];
    assert(!decodeBlob(rawSizeMismatch, blob, status));
    assert(status.error == PbfError.blobRawSizeMismatch);
}

unittest
{
    BlobView blob;
    PbfStatus status;

    // Proto2 int32 -1 is sign-extended and serialized as ten varint bytes.
    const(ubyte)[] negativeRawSize = [
        0x1a, 0x00,
        0x10,
        0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
    ];
    assert(!decodeBlob(negativeRawSize, blob, status));
    assert(status.error == PbfError.invalidBlobRawSize);

    // Exactly 32 MiB violates the exclusive uncompressed-payload hard limit.
    const(ubyte)[] tooLarge = [
        0x1a, 0x00,
        0x10, 0x80, 0x80, 0x80, 0x10,
    ];
    assert(!decodeBlob(tooLarge, blob, status));
    assert(status.error == PbfError.uncompressedBlobTooLarge);

    // Optional codecs are parsed and preserved even before a backend exists.
    const(ubyte)[] lz4 = [
        0x10, 0x00,
        0x32, 0x00,
    ];
    assert(decodeBlob(lz4, blob, status));
    assert(blob.codec == BlobCodec.lz4);
}
