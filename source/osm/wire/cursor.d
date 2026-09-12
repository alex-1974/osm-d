/**
 * Bounded slice-backed cursor over immutable protobuf input bytes.
 *
 * `WireCursor` keeps the unread portion of its borrowed input as a normal D
 * slice. Reads, skips, and takes advance that slice only after checking that
 * enough bytes remain. No raw pointer is stored by the cursor.
 *
 * The benchmark-critical accessors and byte-read primitive are explicitly
 * marked for cross-module inlining. Controlled LDC measurements showed that
 * this is required to avoid a large library-boundary penalty in the varint hot
 * path. See `docs/adr/0008-slice-backed-wire-cursor.md`.
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
 * The cursor never allocates and never owns the underlying bytes. Slices
 * returned by `take` refer to the same caller-owned storage.
 *
 * Notes:
 *   The caller must keep the original storage alive while the cursor or a
 *   slice returned by `take` is used. The cursor itself contains a D slice, so
 *   ordinary bounds and memory-safety rules remain available to `@safe` code.
 */
struct WireCursor
{
private:
    const(ubyte)[] _remaining;
    size_t _offset;

public:
    /**
     * Construct a cursor over `input`.
     *
     * Params:
     *   input = Immutable bytes borrowed by the cursor.
     */
    this(const(ubyte)[] input) @safe pure nothrow @nogc
    {
        _remaining = input;
        _offset = 0;
    }

    /** Returns `true` when no unread bytes remain. */
    pragma(inline, true)
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _remaining.length == 0;
    }

    /** Returns the number of bytes consumed from the original input. */
    pragma(inline, true)
    @property size_t offset() const @safe pure nothrow @nogc
    {
        return _offset;
    }

    /** Returns the number of unread bytes. */
    @property size_t remaining() const @safe pure nothrow @nogc
    {
        return _remaining.length;
    }

    /**
     * Read one byte and advance the cursor.
     *
     * Params:
     *   value = Receives the byte on success.
     *
     * Returns:
     *   `true` when one byte was available; `false` at end of input.
     */
    pragma(inline, true)
    bool readByte(out ubyte value) @safe nothrow @nogc
    {
        if (_remaining.length == 0)
            return false;

        value = _remaining[0];
        _remaining = _remaining[1 .. $];
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
    bool skip(size_t count) @safe nothrow @nogc
    {
        if (count > _remaining.length)
            return false;

        _remaining = _remaining[count .. $];
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
     *   The returned slice owns no memory and is valid only while the original
     *   input storage remains valid.
     */
    bool take(size_t count, out const(ubyte)[] bytes) @safe nothrow @nogc
    {
        if (count > _remaining.length)
        {
            bytes = null;
            return false;
        }

        if (count == 0)
        {
            bytes = null;
            return true;
        }

        bytes = _remaining[0 .. count];
        _remaining = _remaining[count .. $];
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
