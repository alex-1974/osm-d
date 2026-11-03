/**
 * Small allocation-aware protobuf encoding primitives.
 *
 * These package-internal helpers are the write-side counterpart to
 * `osm.wire` decoding. They append canonical varint and length-delimited
 * encodings to caller-owned byte arrays and make allocation explicit at the
 * outer writer boundary.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.wire.writer;

import osm.wire.zigzag : encodeZigZag64;

package(osm)
{
    /** Append one canonical unsigned protobuf varint. */
    void appendVarint(ref ubyte[] target, ulong value) @safe
    {
        do
        {
            ubyte byteValue = cast(ubyte)(value & 0x7f);
            value >>= 7;
            if (value != 0)
                byteValue |= 0x80;
            target ~= byteValue;
        }
        while (value != 0);
    }

    /** Append a varint field key followed by an unsigned value. */
    void appendVarintField(
        ref ubyte[] target,
        uint fieldNumber,
        ulong value)
        @safe
    {
        appendVarint(target, cast(ulong)(fieldNumber << 3));
        appendVarint(target, value);
    }

    /** Append a protobuf sint64 field using canonical ZigZag encoding. */
    void appendSInt64Field(
        ref ubyte[] target,
        uint fieldNumber,
        long value)
        @safe
    {
        appendVarintField(target, fieldNumber, encodeZigZag64(value));
    }

    /** Append a protobuf int64 field, including canonical 10-byte negatives. */
    void appendInt64Field(
        ref ubyte[] target,
        uint fieldNumber,
        long value)
        @safe
    {
        appendVarintField(target, fieldNumber, cast(ulong)value);
    }

    /** Append a protobuf int32 field with sign extension for negative values. */
    void appendInt32Field(
        ref ubyte[] target,
        uint fieldNumber,
        int value)
        @safe
    {
        appendVarintField(
            target,
            fieldNumber,
            cast(ulong)cast(long)value);
    }

    /** Append one length-delimited field. */
    void appendLengthDelimited(
        ref ubyte[] target,
        uint fieldNumber,
        scope const(ubyte)[] value)
        @safe
    {
        appendVarint(
            target,
            cast(ulong)((fieldNumber << 3) | 2));
        appendVarint(target, value.length);
        target ~= value;
    }

    /** Append a four-byte network-order unsigned integer. */
    void appendBigEndianU32(ref ubyte[] target, uint value) @safe
    {
        target ~= cast(ubyte)(value >> 24);
        target ~= cast(ubyte)(value >> 16);
        target ~= cast(ubyte)(value >> 8);
        target ~= cast(ubyte)value;
    }
}

unittest
{
    ubyte[] encoded;
    appendVarint(encoded, 300);
    assert(encoded == [0xac, 0x02]);

    encoded.length = 0;
    appendSInt64Field(encoded, 1, -1);
    assert(encoded == [0x08, 0x01]);

    encoded.length = 0;
    appendLengthDelimited(encoded, 2, [0xaa, 0xbb]);
    assert(encoded == [0x12, 0x02, 0xaa, 0xbb]);
}
