/**
 * Bounded cursor over immutable protobuf input bytes.
 *
 * Pointer arithmetic is intentionally confined to this module. Construction
 * starts from a D slice and every read, take, or skip operation checks the
 * tracked remaining byte count before dereferencing or constructing a returned
 * slice.
 *
 * The constructor is `@system` because the cursor stores a borrowed raw pointer
 * whose lifetime cannot be expressed by the type itself. Individual operations
 * are exposed through narrowly reviewed `@trusted` methods after bounds checks.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.wire.cursor;

/**
 * Mutable read cursor over one borrowed immutable wire buffer.
 *
 * A `WireCursor` never allocates and never owns the underlying memory. It must
 * not outlive the slice used to construct it.
 */
struct WireCursor
{
private:
    const(ubyte)* _ptr;
    size_t _remaining;
    size_t _offset;

public:
    /**
     * Construct a cursor over `input`.
     *
     * Params:
     *   input = Immutable byte range borrowed for the lifetime of the cursor.
     *
     * Safety:
     *   The caller must ensure that `input` remains alive and unmoved for every
     *   operation performed through this cursor.
     */
    this(const(ubyte)[] input) @system nothrow @nogc
    {
        _ptr = input.ptr;
        _remaining = input.length;
        _offset = 0;
    }

    /** Returns `true` when no unread bytes remain. */
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _remaining == 0;
    }

    /** Returns the number of bytes consumed from the original input. */
    @property size_t offset() const @safe pure nothrow @nogc
    {
        return _offset;
    }

    /** Returns the number of unread bytes. */
    @property size_t remaining() const @safe pure nothrow @nogc
    {
        return _remaining;
    }

    /**
     * Read one byte and advance the cursor.
     *
     * Params:
     *   value = Receives the byte on success.
     *
     * Returns:
     *   `true` if a byte was available; `false` at end of input.
     */
    bool readByte(out ubyte value) @trusted nothrow @nogc
    {
        if (_remaining == 0)
            return false;

        value = *_ptr++;
        --_remaining;
        ++_offset;
        return true;
    }

    /**
     * Advance the cursor by `count` bytes without reading them.
     *
     * Params:
     *   count = Number of bytes to skip.
     *
     * Returns:
     *   `true` if `count` bytes were available; `false` otherwise.
     */
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

    /**
     * Borrow the next `count` bytes and advance the cursor.
     *
     * Params:
     *   count = Number of bytes to borrow.
     *   bytes = Receives a slice into the original input on success.
     *
     * Returns:
     *   `true` if `count` bytes were available; `false` otherwise.
     *
     * Notes:
     *   The returned slice has the same lifetime constraints as this cursor and
     *   does not own or copy its bytes.
     */
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
