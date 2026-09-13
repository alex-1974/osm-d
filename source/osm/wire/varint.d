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
 * Decode one unsigned 32-bit protobuf varint.
 *
 * Params:
 *   cursor = Cursor positioned at the first byte of the varint.
 *   value = Receives the decoded value on success.
 *   status = Receives success or a wire-decoding failure.
 *
 * Returns:
 *   `true` when the encoded value fits in `uint`; `false` otherwise.
 */
bool readVarint32(ref WireCursor cursor, out uint value, out WireStatus status)
    @safe nothrow @nogc
{
    const start = cursor.offset;
    ulong wide;
    if (!readVarint64(cursor, wide, status))
    {
        value = 0;
        return false;
    }

    if (wide > uint.max)
    {
        value = 0;
        status = WireStatus.failure(WireError.varintOverflow, start);
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
 * Decode one protobuf `sint32` value.
 *
 * Params:
 *   cursor = Cursor positioned at the first byte of the encoded varint.
 *   value = Receives the ZigZag-decoded signed value on success.
 *   status = Receives success or a wire-decoding failure.
 *
 * Returns:
 *   `true` on success; `false` if the underlying varint is invalid or exceeds
 *   the supported 32-bit encoded width.
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
    WireStatus status;
    long value;

    const(ubyte)[] minusOne = [0x01];
    auto cursor = WireCursor(minusOne);
    assert(readSVarint64(cursor, value, status));
    assert(value == -1);
}
