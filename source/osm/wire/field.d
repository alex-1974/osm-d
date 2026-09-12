/**
 * Protobuf field-key and primitive field-value handling.
 *
 * This module deliberately stops below generated-message semantics. It knows
 * protobuf wire types, not OSM or OSMPBF message schemas.
 */
module osm.wire.field;

import osm.wire.cursor : WireCursor;
import osm.wire.error : WireError, WireStatus;
import osm.wire.varint : readVarint64;

/// Protobuf wire types encoded in the low three bits of a field key.
enum WireType : ubyte
{
    varint = 0,
    fixed64 = 1,
    lengthDelimited = 2,
    startGroup = 3,
    endGroup = 4,
    fixed32 = 5,
}

struct FieldHeader
{
    uint number;
    WireType wireType;
    size_t offset;
}

/** Decode one protobuf field key. */
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
 * The cursor must point at the length varint, i.e. directly after the field
 * key. Returned bytes borrow the cursor's original input buffer.
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
 * Skip a primitive protobuf field value.
 *
 * Groups are recognized by `readFieldHeader`, but intentionally not skipped
 * yet because correct group skipping requires matching nested end-group field
 * numbers and a bounded nesting policy. OSMPBF schemas do not use groups.
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
