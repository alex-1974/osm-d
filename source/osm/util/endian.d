/**
 * Bounds-checked endian decoding helpers for binary format code.
 *
 * These helpers are package-internal implementation primitives. They decode
 * fixed-width integers from caller-owned byte slices without alignment
 * assumptions, pointer casts, allocation, or host-endian dependence.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.util.endian;

package(osm)
{
    /**
     * Decode one big-endian 32-bit unsigned integer at `offset`.
     *
     * Returns false and resets `value` to zero when fewer than four bytes
     * remain. The input slice is never modified.
     */
    pragma(inline, true)
    bool readBigEndianU32(
        scope const(ubyte)[] bytes,
        size_t offset,
        out uint value)
        @safe pure nothrow @nogc
    {
        if (offset > bytes.length || bytes.length - offset < 4)
        {
            value = 0;
            return false;
        }

        value = (cast(uint)bytes[offset] << 24)
              | (cast(uint)bytes[offset + 1] << 16)
              | (cast(uint)bytes[offset + 2] << 8)
              | cast(uint)bytes[offset + 3];
        return true;
    }

    /**
     * Decode one little-endian 32-bit unsigned integer at `offset`.
     *
     * Returns false and resets `value` to zero when fewer than four bytes
     * remain.
     */
    pragma(inline, true)
    bool readLittleEndianU32(
        scope const(ubyte)[] bytes,
        size_t offset,
        out uint value)
        @safe pure nothrow @nogc
    {
        if (offset > bytes.length || bytes.length - offset < 4)
        {
            value = 0;
            return false;
        }

        value = cast(uint)bytes[offset]
              | (cast(uint)bytes[offset + 1] << 8)
              | (cast(uint)bytes[offset + 2] << 16)
              | (cast(uint)bytes[offset + 3] << 24);
        return true;
    }

    /**
     * Decode one little-endian 64-bit unsigned integer at `offset`.
     *
     * Returns false and resets `value` to zero when fewer than eight bytes
     * remain.
     */
    pragma(inline, true)
    bool readLittleEndianU64(
        scope const(ubyte)[] bytes,
        size_t offset,
        out ulong value)
        @safe pure nothrow @nogc
    {
        if (offset > bytes.length || bytes.length - offset < 8)
        {
            value = 0;
            return false;
        }

        value = cast(ulong)bytes[offset]
              | (cast(ulong)bytes[offset + 1] << 8)
              | (cast(ulong)bytes[offset + 2] << 16)
              | (cast(ulong)bytes[offset + 3] << 24)
              | (cast(ulong)bytes[offset + 4] << 32)
              | (cast(ulong)bytes[offset + 5] << 40)
              | (cast(ulong)bytes[offset + 6] << 48)
              | (cast(ulong)bytes[offset + 7] << 56);
        return true;
    }
}

unittest
{
    uint value = uint.max;

    const(ubyte)[] exact = [0x12, 0x34, 0x56, 0x78];
    assert(readBigEndianU32(exact, 0, value));
    assert(value == 0x1234_5678U);

    const(ubyte)[] offset = [0xff, 0x89, 0xab, 0xcd, 0xef, 0xee];
    assert(readBigEndianU32(offset, 1, value));
    assert(value == 0x89ab_cdefU);

    const(ubyte)[] shortInput = [0x12, 0x34, 0x56];
    value = uint.max;
    assert(!readBigEndianU32(shortInput, 0, value));
    assert(value == 0);

    value = uint.max;
    assert(!readBigEndianU32(exact, exact.length + 1, value));
    assert(value == 0);
}

unittest
{
    uint value32;
    const(ubyte)[] bytes32 = [0x78, 0x56, 0x34, 0x12];
    assert(readLittleEndianU32(bytes32, 0, value32));
    assert(value32 == 0x1234_5678U);

    ulong value64;
    const(ubyte)[] bytes64 = [
        0xef, 0xcd, 0xab, 0x89,
        0x67, 0x45, 0x23, 0x01,
    ];
    assert(readLittleEndianU64(bytes64, 0, value64));
    assert(value64 == 0x0123_4567_89ab_cdefUL);

    value64 = ulong.max;
    assert(!readLittleEndianU64(bytes64[0 .. 7], 0, value64));
    assert(value64 == 0);
}
