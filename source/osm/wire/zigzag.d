/**
 * Protobuf ZigZag integer transforms.
 *
 * ZigZag maps signed integers to unsigned integers so that values with small
 * absolute magnitude retain short varint encodings. All operations are pure,
 * allocation-free, and defined over the full 32- and 64-bit input domains.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.wire.zigzag;

/**
 * Decode a protobuf `sint64` payload after varint decoding.
 *
 * Params:
 *   value = Unsigned ZigZag-encoded 64-bit value.
 *
 * Returns:
 *   The corresponding signed 64-bit value.
 */
long decodeZigZag64(ulong value) @safe pure nothrow @nogc
{
    return cast(long)(value >> 1) ^ -cast(long)(value & 1UL);
}

/**
 * Decode a protobuf `sint32` payload after varint decoding.
 *
 * Params:
 *   value = Unsigned ZigZag-encoded 32-bit value.
 *
 * Returns:
 *   The corresponding signed 32-bit value.
 */
int decodeZigZag32(uint value) @safe pure nothrow @nogc
{
    return cast(int)(value >> 1) ^ -cast(int)(value & 1U);
}

/**
 * Encode a signed 64-bit value using the protobuf ZigZag transform.
 *
 * Params:
 *   value = Signed value to encode.
 *
 * Returns:
 *   The ZigZag-encoded unsigned 64-bit value.
 */
ulong encodeZigZag64(long value) @safe pure nothrow @nogc
{
    return (cast(ulong)value << 1) ^ cast(ulong)(value >> 63);
}

/**
 * Encode a signed 32-bit value using the protobuf ZigZag transform.
 *
 * Params:
 *   value = Signed value to encode.
 *
 * Returns:
 *   The ZigZag-encoded unsigned 32-bit value.
 */
uint encodeZigZag32(int value) @safe pure nothrow @nogc
{
    return (cast(uint)value << 1) ^ cast(uint)(value >> 31);
}

unittest
{
    assert(decodeZigZag64(0) == 0);
    assert(decodeZigZag64(1) == -1);
    assert(decodeZigZag64(2) == 1);
    assert(decodeZigZag64(3) == -2);
    assert(decodeZigZag64(ulong.max) == long.min);

    foreach (value; [long.min, -100L, -1L, 0L, 1L, 100L, long.max])
        assert(decodeZigZag64(encodeZigZag64(value)) == value);
}
