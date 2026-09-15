/**
 * Protobuf base-128 varint decoding.
 *
 * The decoder accepts legal non-minimal encodings up to the protobuf 64-bit
 * maximum of ten bytes. It rejects truncation and values whose tenth byte
 * contains bits outside bit zero. The common one-byte case has an explicit
 * fast path. The 64-bit decoder is explicitly marked for cross-module inlining
 * because controlled LDC benchmarks found the library boundary otherwise
 * dominates this hot path.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.wire.varint;

import osm.wire.cursor : WireCursor;
import osm.wire.error : WireError, WireStatus;
import osm.wire.zigzag : decodeZigZag32, decodeZigZag64;

/**
 * Decode one unsigned 64-bit protobuf varint.
 *
 * Params:
 *   cursor = Cursor positioned at the first byte of the varint.
 *   value = Receives the decoded value on success.
 *   status = Receives success or a precise wire-decoding failure.
 *
 * Returns:
 *   `true` on success; `false` for truncated or overflowing encodings.
 *
 * Notes:
 *   Legal non-minimal protobuf encodings are accepted. On failure `value` is
 *   reset to zero, while the cursor remains advanced to the point at which the
 *   failure was detected.
 */
pragma(inline, true)
bool readVarint64(ref WireCursor cursor, out ulong value, out WireStatus status)
    @safe nothrow @nogc
{
    const start = cursor.offset;

    ubyte first;
    if (!cursor.readByte(first))
    {
        value = 0;
        status = WireStatus.failure(WireError.truncatedVarint, start);
        return false;
    }

    // One-byte varints dominate protobuf field keys and many small values.
    if ((first & 0x80) == 0)
    {
        value = first;
        status = WireStatus.init;
        return true;
    }

    ulong result = first & 0x7fUL;
    uint shift = 7;

    // Bytes 2..9 contribute seven bits each.
    foreach (_; 1 .. 9)
    {
        ubyte b;
        if (!cursor.readByte(b))
        {
            value = 0;
            status = WireStatus.failure(WireError.truncatedVarint, start);
            return false;
        }

        result |= cast(ulong)(b & 0x7f) << shift;
        if ((b & 0x80) == 0)
        {
            value = result;
            status = WireStatus.init;
            return true;
        }
        shift += 7;
    }

    // A uint64 varint may use a tenth byte, but only bit zero may be set.
    ubyte last;
    if (!cursor.readByte(last))
    {
        value = 0;
        status = WireStatus.failure(WireError.truncatedVarint, start);
        return false;
    }

    if (last > 1)
    {
        value = 0;
        status = WireStatus.failure(WireError.varintOverflow, start);
        return false;
    }

    result |= cast(ulong)last << 63;
    value = result;
    status = WireStatus.init;
    return true;
}

/**
 * Decode one protobuf 32-bit varint value.
 *
 * Protobuf scalar parsing consumes a complete legal 64-bit varint and keeps
 * the low 32 bits for 32-bit integer field types. This deliberately differs
 * from length/size decoding, where truncation would be unsafe.
 *
 * Params:
 *   cursor = Cursor positioned at the first byte of the varint.
 *   value = Receives the low 32 bits of the decoded wire value.
 *   status = Receives success or a wire-decoding failure.
 *
 * Returns:
 *   `true` for every legal protobuf varint; `false` only when the underlying
 *   64-bit varint is malformed or truncated.
 */
bool readVarint32(ref WireCursor cursor, out uint value, out WireStatus status)
    @safe nothrow @nogc
{
    ulong wide;
    if (!readVarint64(cursor, wide, status))
    {
        value = 0;
        return false;
    }

    value = cast(uint)wide;
    return true;
}

/**
 * Decode one protobuf `sint64` value.
 *
 * Params:
 *   cursor = Cursor positioned at the first byte of the encoded varint.
 *   value = Receives the ZigZag-decoded signed value on success.
 *   status = Receives success or a wire-decoding failure.
 *
 * Returns:
 *   `true` on success; `false` if the underlying varint is invalid.
 */
pragma(inline, true)
bool readSVarint64(ref WireCursor cursor, out long value, out WireStatus status)
    @safe nothrow @nogc
{
    ulong encoded;
    if (!readVarint64(cursor, encoded, status))
    {
        value = 0;
        return false;
    }

    value = decodeZigZag64(encoded);
    return true;
}


/**
 * Decode one protobuf `sint64` for an internal failure-only status consumer.
 *
 * Successful decoding deliberately leaves `status` unchanged. On failure the
 * value, cursor advancement, error, and error offset match `readSVarint64`.
 *
 * This hot-path specialization intentionally mirrors the public uint64 varint
 * state machine locally in the wire layer. Factoring both paths through one
 * helper changed LDC code generation for unrelated public wire readers, while
 * this form confines the optimization to callers that explicitly opt into the
 * failure-only contract. The equivalence tests below lock the shared wire
 * semantics.
 */
package(osm)
{
    pragma(inline, true)
    bool readSVarint64FailureOnly(
        ref WireCursor cursor,
        out long value,
        ref WireStatus status)
        @safe nothrow @nogc
    {
        const start = cursor.offset;

        ubyte first;
        if (!cursor.readByte(first))
        {
            value = 0;
            status = WireStatus.failure(WireError.truncatedVarint, start);
            return false;
        }

        if ((first & 0x80) == 0)
        {
            value = decodeZigZag64(first);
            return true;
        }

        ulong result = first & 0x7fUL;
        uint shift = 7;

        // Bytes 2..9 contribute seven bits each.
        foreach (_; 1 .. 9)
        {
            ubyte b;
            if (!cursor.readByte(b))
            {
                value = 0;
                status = WireStatus.failure(
                    WireError.truncatedVarint,
                    start);
                return false;
            }

            result |= cast(ulong)(b & 0x7f) << shift;

            if ((b & 0x80) == 0)
            {
                value = decodeZigZag64(result);
                return true;
            }

            shift += 7;
        }

        // A uint64 varint may use a tenth byte, but only bit zero may be set.
        ubyte last;
        if (!cursor.readByte(last))
        {
            value = 0;
            status = WireStatus.failure(WireError.truncatedVarint, start);
            return false;
        }

        if (last > 1)
        {
            value = 0;
            status = WireStatus.failure(WireError.varintOverflow, start);
            return false;
        }

        result |= cast(ulong)last << 63;
        value = decodeZigZag64(result);
        return true;
    }
}

/**
 * Decode one protobuf `sint32` value.
 *
 * Params:
 *   cursor = Cursor positioned at the first byte of the encoded varint.
 *   value = Receives the ZigZag-decoded signed value on success.
 *   status = Receives success or a wire-decoding failure.
 *
 * Returns:
 *   `true` on success; `false` only if the underlying 64-bit varint is invalid.
 *
 * Notes:
 *   As for protobuf generated parsers, over-wide legal varints are truncated
 *   to 32 bits before ZigZag decoding.
 */
bool readSVarint32(ref WireCursor cursor, out int value, out WireStatus status)
    @safe nothrow @nogc
{
    uint encoded;
    if (!readVarint32(cursor, encoded, status))
    {
        value = 0;
        return false;
    }

    value = decodeZigZag32(encoded);
    return true;
}

unittest
{
    WireStatus status;
    ulong value;

    const(ubyte)[] single = [0x7f];
    auto a = WireCursor(single);
    assert(readVarint64(a, value, status));
    assert(status.ok && value == 127 && a.empty);

    const(ubyte)[] threeHundred = [0xac, 0x02];
    auto b = WireCursor(threeHundred);
    assert(readVarint64(b, value, status));
    assert(status.ok && value == 300 && b.empty);

    const(ubyte)[] max64 = [0xff, 0xff, 0xff, 0xff, 0xff,
                            0xff, 0xff, 0xff, 0xff, 0x01];
    auto c = WireCursor(max64);
    assert(readVarint64(c, value, status));
    assert(value == ulong.max);
}

unittest
{
    WireStatus status;
    ulong value;

    const(ubyte)[] truncated = [0x80];
    auto a = WireCursor(truncated);
    assert(!readVarint64(a, value, status));
    assert(status.error == WireError.truncatedVarint);
    assert(status.offset == 0);

    const(ubyte)[] overflow = [0xff, 0xff, 0xff, 0xff, 0xff,
                               0xff, 0xff, 0xff, 0xff, 0x02];
    auto b = WireCursor(overflow);
    assert(!readVarint64(b, value, status));
    assert(status.error == WireError.varintOverflow);
}

unittest
{
    // Protobuf 32-bit scalar reads consume a legal 64-bit varint and truncate
    // the high bits, matching generated parser semantics.
    WireStatus status;

    const(ubyte)[] wide = [
        0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01
    ];

    uint u32;
    auto a = WireCursor(wide);
    assert(readVarint32(a, u32, status));
    assert(status.ok && u32 == uint.max && a.empty);

    int s32;
    auto b = WireCursor(wide);
    assert(readSVarint32(b, s32, status));
    assert(status.ok && s32 == int.min && b.empty);
}

unittest
{
    WireStatus status;
    long value;

    const(ubyte)[] minusOne = [0x01];
    auto cursor = WireCursor(minusOne);
    assert(readSVarint64(cursor, value, status));
    assert(value == -1);
}


unittest
{
    // Success preserves the caller's status in the failure-only variant.
    WireStatus status =
        WireStatus.failure(WireError.varintOverflow, 123, 7);

    long value;

    const(ubyte)[] oneByte = [0x01];
    auto a = WireCursor(oneByte);

    assert(readSVarint64FailureOnly(a, value, status));
    assert(value == -1);
    assert(a.empty);
    assert(status.error == WireError.varintOverflow);
    assert(status.offset == 123);
    assert(status.fieldNumber == 7);
}

unittest
{
    // Public and failure-only sint64 decoding have identical wire semantics.
    static const(ubyte)[][] encodings = [
        [0x00],
        [0x01],
        [0x02],
        [0x7f],
        [0x80, 0x00], // legal non-minimal zero
        [0x81, 0x00], // legal non-minimal one
        [0xac, 0x02],
        [
            0xff, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff, 0x01
        ],
    ];

    foreach (encoded; encodings)
    {
        WireStatus publicStatus;
        WireStatus internalStatus =
            WireStatus.failure(WireError.varintOverflow, 999, 42);

        long publicValue;
        long internalValue;

        auto publicCursor = WireCursor(encoded);
        auto internalCursor = WireCursor(encoded);

        assert(readSVarint64(
            publicCursor,
            publicValue,
            publicStatus));

        assert(readSVarint64FailureOnly(
            internalCursor,
            internalValue,
            internalStatus));

        assert(publicValue == internalValue);
        assert(publicCursor.offset == internalCursor.offset);
        assert(publicStatus.ok);

        // The failure-only contract deliberately preserves prior status.
        assert(internalStatus.error == WireError.varintOverflow);
        assert(internalStatus.offset == 999);
        assert(internalStatus.fieldNumber == 42);
    }
}

unittest
{
    // Failure value/cursor/error semantics remain identical.
    static const(ubyte)[][] malformed = [
        [],
        [0x80],
        [0x80, 0x80],
        [
            0xff, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff
        ],
        [
            0xff, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff, 0x02
        ],
    ];

    foreach (encoded; malformed)
    {
        WireStatus publicStatus;
        WireStatus internalStatus;

        long publicValue = 123;
        long internalValue = 456;

        auto publicCursor = WireCursor(encoded);
        auto internalCursor = WireCursor(encoded);

        assert(!readSVarint64(
            publicCursor,
            publicValue,
            publicStatus));

        assert(!readSVarint64FailureOnly(
            internalCursor,
            internalValue,
            internalStatus));

        assert(publicValue == 0);
        assert(internalValue == 0);

        assert(publicCursor.offset == internalCursor.offset);
        assert(publicStatus.error == internalStatus.error);
        assert(publicStatus.offset == internalStatus.offset);
        assert(publicStatus.fieldNumber == internalStatus.fieldNumber);
    }
}
