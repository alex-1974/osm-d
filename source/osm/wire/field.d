/**
 * Protobuf field-key and primitive field-value handling.
 *
 * This module deliberately stops below generated-message semantics. It knows
 * protobuf field numbers and wire types, but nothing about OSM or OSMPBF
 * message schemas.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.wire.field;

import osm.wire.cursor : WireCursor;
import osm.wire.error : WireError, WireStatus;
import osm.wire.varint : readVarint64;

/** Protobuf wire types encoded in the low three bits of a field key. */
enum WireType : ubyte
{
    /// Base-128 varint.
    varint = 0,
    /// Little-endian 64-bit fixed-width value.
    fixed64 = 1,
    /// Length-prefixed byte sequence, embedded message, string, or packed data.
    lengthDelimited = 2,
    /// Start of a deprecated protobuf group.
    startGroup = 3,
    /// End of a deprecated protobuf group.
    endGroup = 4,
    /// Little-endian 32-bit fixed-width value.
    fixed32 = 5,
}

/** Decoded protobuf field key together with its source offset. */
struct FieldHeader
{
    /// Protobuf field number in the inclusive range `1 .. 2^29 - 1`.
    uint number;
    /// Wire representation used by the field value.
    WireType wireType;
    /// Byte offset at which the field key started.
    size_t offset;
}

/**
 * Decode one protobuf field key.
 *
 * Params:
 *   cursor = Cursor positioned at the first byte of a field key.
 *   header = Receives the validated field number, wire type, and source offset.
 *   status = Receives success or a field-key decoding failure.
 *
 * Returns:
 *   `true` when a valid protobuf field key was decoded; `false` otherwise.
 */
bool readFieldHeader(ref WireCursor cursor, out FieldHeader header, out WireStatus status)
    @safe nothrow @nogc
{
    const start = cursor.offset;

    ulong key;
    if (!readVarint64(cursor, key, status))
    {
        header = FieldHeader.init;
        return false;
    }

    const fieldNumber = key >> 3;
    const rawWireType = key & 0x07;

    // Protobuf field numbers are 1..2^29-1.
    if (fieldNumber == 0 || fieldNumber > 0x1fff_ffffUL)
    {
        header = FieldHeader.init;
        status = WireStatus.failure(WireError.invalidFieldNumber, start);
        return false;
    }

    if (rawWireType > cast(ulong)WireType.fixed32)
    {
        header = FieldHeader.init;
        status = WireStatus.failure(
            WireError.invalidWireType,
            start,
            cast(uint)fieldNumber);
        return false;
    }

    header = FieldHeader(
        cast(uint)fieldNumber,
        cast(WireType)rawWireType,
        start);
    status = WireStatus.init;
    return true;
}

/**
 * Read a length-delimited field payload as a borrowed slice.
 *
 * The cursor must point at the length varint, directly after the field key.
 * Returned bytes borrow the cursor's original input buffer and are never
 * copied.
 *
 * Params:
 *   cursor = Cursor positioned at the field's encoded length.
 *   fieldNumber = Field number used for error reporting.
 *   bytes = Receives the borrowed payload slice on success.
 *   status = Receives success or a length/payload decoding failure.
 *
 * Returns:
 *   `true` when the complete payload is present and its length fits `size_t`;
 *   `false` otherwise.
 */
bool readLengthDelimited(
    ref WireCursor cursor,
    uint fieldNumber,
    out const(ubyte)[] bytes,
    out WireStatus status)
    @safe nothrow @nogc
{
    const start = cursor.offset;

    ulong encodedLength;
    if (!readVarint64(cursor, encodedLength, status))
    {
        bytes = null;
        if (status.fieldNumber == 0)
            status.fieldNumber = fieldNumber;
        return false;
    }

    if (encodedLength > cast(ulong)size_t.max)
    {
        bytes = null;
        status = WireStatus.failure(WireError.lengthOverflow, start, fieldNumber);
        return false;
    }

    const length = cast(size_t)encodedLength;
    if (!cursor.take(length, bytes))
    {
        bytes = null;
        status = WireStatus.failure(WireError.truncatedInput, start, fieldNumber);
        return false;
    }

    status = WireStatus.init;
    return true;
}

/**
 * Skip one primitive protobuf field value.
 *
 * Groups are recognized by `readFieldHeader`, but intentionally not skipped
 * yet because correct group skipping requires matching nested end-group field
 * numbers and a bounded nesting policy. Current OSMPBF schemas do not use
 * groups, so encountering one fails closed instead of silently discarding it.
 *
 * Params:
 *   cursor = Cursor positioned immediately after the field key.
 *   header = Previously decoded field header.
 *   status = Receives success or the reason the value could not be skipped.
 *
 * Returns:
 *   `true` if the complete field value was safely skipped; `false` otherwise.
 */
bool skipFieldValue(
    ref WireCursor cursor,
    FieldHeader header,
    out WireStatus status)
    @safe nothrow @nogc
{
    final switch (header.wireType)
    {
        case WireType.varint:
            ulong ignored;
            if (!readVarint64(cursor, ignored, status))
            {
                if (status.fieldNumber == 0)
                    status.fieldNumber = header.number;
                return false;
            }
            return true;

        case WireType.fixed64:
            if (!cursor.skip(8))
            {
                status = WireStatus.failure(
                    WireError.truncatedInput,
                    cursor.offset,
                    header.number);
                return false;
            }
            status = WireStatus.init;
            return true;

        case WireType.lengthDelimited:
            const(ubyte)[] ignored;
            return readLengthDelimited(cursor, header.number, ignored, status);

        case WireType.fixed32:
            if (!cursor.skip(4))
            {
                status = WireStatus.failure(
                    WireError.truncatedInput,
                    cursor.offset,
                    header.number);
                return false;
            }
            status = WireStatus.init;
            return true;

        case WireType.startGroup:
        case WireType.endGroup:
            status = WireStatus.failure(
                WireError.unsupportedGroup,
                header.offset,
                header.number);
            return false;
    }
}

unittest
{
    // field 1, wire type 2, length 3, payload "OSM"
    const(ubyte)[] bytes = [0x0a, 0x03, 0x4f, 0x53, 0x4d];
    auto cursor = WireCursor(bytes);

    FieldHeader header;
    WireStatus status;
    assert(readFieldHeader(cursor, header, status));
    assert(header.number == 1);
    assert(header.wireType == WireType.lengthDelimited);

    const(ubyte)[] payload;
    assert(readLengthDelimited(cursor, header.number, payload, status));
    const(ubyte)[] expected = [0x4f, 0x53, 0x4d];
    assert(payload == expected);
    assert(cursor.empty);
}

unittest
{
    FieldHeader header;
    WireStatus status;

    const(ubyte)[] zeroField = [0x00];
    auto a = WireCursor(zeroField);
    assert(!readFieldHeader(a, header, status));
    assert(status.error == WireError.invalidFieldNumber);

    const(ubyte)[] invalidWire = [0x0e]; // field 1, wire type 6
    auto b = WireCursor(invalidWire);
    assert(!readFieldHeader(b, header, status));
    assert(status.error == WireError.invalidWireType);
}

unittest
{
    // Unknown field 4, fixed32, followed by a known field key.
    const(ubyte)[] bytes = [0x25, 1, 2, 3, 4, 0x08, 0x01];
    auto cursor = WireCursor(bytes);

    FieldHeader header;
    WireStatus status;
    assert(readFieldHeader(cursor, header, status));
    assert(header.number == 4 && header.wireType == WireType.fixed32);
    assert(skipFieldValue(cursor, header, status));

    assert(readFieldHeader(cursor, header, status));
    assert(header.number == 1 && header.wireType == WireType.varint);
}
