/**
 * Bounded cursor over immutable protobuf input bytes.
 *
 * Pointer arithmetic is intentionally confined to this module. Construction
 * starts from a D slice and every read/take/skip operation checks the tracked
 * remaining byte count before dereferencing or constructing a returned slice.
 */
module osm.wire.cursor;

struct WireCursor
{
private:
    const(ubyte)* _ptr;
    size_t _remaining;
    size_t _offset;

public:
    this(const(ubyte)[] input) @system nothrow @nogc
    {
        _ptr = input.ptr;
        _remaining = input.length;
        _offset = 0;
    }

    @property bool empty() const @safe pure nothrow @nogc
    {
        return _remaining == 0;
    }

    @property size_t offset() const @safe pure nothrow @nogc
    {
        return _offset;
    }

    @property size_t remaining() const @safe pure nothrow @nogc
    {
        return _remaining;
    }

    bool readByte(out ubyte value) @trusted nothrow @nogc
    {
        if (_remaining == 0)
            return false;

        value = *_ptr++;
        --_remaining;
        ++_offset;
        return true;
    }

    bool skip(size_t count) @trusted nothrow @nogc
    {
        if (count > _remaining)
            return false;

        if (count != 0)
            _ptr += count;
        _remaining -= count;
        _offset += count;
        return true;
    }

    bool take(size_t count, out const(ubyte)[] bytes) @trusted nothrow @nogc
    {
        if (count > _remaining)
        {
            bytes = null;
            return false;
        }

        if (count == 0)
        {
            bytes = null;
            return true;
        }

        bytes = _ptr[0 .. count];
        _ptr += count;
        _remaining -= count;
        _offset += count;
        return true;
    }
}

unittest
{
    const(ubyte)[] bytes = [0x11, 0x22, 0x33];
    auto cursor = WireCursor(bytes);

    assert(cursor.offset == 0);
    assert(cursor.remaining == 3);

    ubyte value;
    assert(cursor.readByte(value) && value == 0x11);
    assert(cursor.offset == 1);

    const(ubyte)[] tail;
    assert(cursor.take(2, tail));
    const(ubyte)[] expected = [0x22, 0x33];
    assert(tail == expected);
    assert(cursor.empty);
    assert(!cursor.readByte(value));
}

unittest
{
    const(ubyte)[] bytes;
    auto cursor = WireCursor(bytes);
    assert(cursor.empty);
    assert(cursor.remaining == 0);

    const(ubyte)[] part;
    assert(cursor.take(0, part));
    assert(part.length == 0);
    assert(!cursor.skip(1));
}
