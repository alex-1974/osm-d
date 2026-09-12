/**
 * Protobuf ZigZag integer transforms.
 */
module osm.wire.zigzag;

/// Decode a protobuf `sint64` payload after varint decoding.
long decodeZigZag64(ulong value) @safe pure nothrow @nogc
{
    return cast(long)(value >> 1) ^ -cast(long)(value & 1UL);
}

/// Decode a protobuf `sint32` payload after varint decoding.
int decodeZigZag32(uint value) @safe pure nothrow @nogc
{
    return cast(int)(value >> 1) ^ -cast(int)(value & 1U);
}

/// Encode a signed 64-bit value using the protobuf ZigZag transform.
ulong encodeZigZag64(long value) @safe pure nothrow @nogc
{
    return (cast(ulong)value << 1) ^ cast(ulong)(value >> 63);
}

/// Encode a signed 32-bit value using the protobuf ZigZag transform.
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
