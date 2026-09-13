/**
 * Indexed zero-copy view of merged OSMPBF StringTable entries.
 *
 * `PrimitiveBlock` decoding first validates and counts all StringTable entries.
 * This module then fills caller-owned `StringRef` storage with compact offsets
 * and lengths into the original PrimitiveBlock. No string bytes are copied and
 * no GC allocation is performed.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.string_table;

import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.primitive_block : PrimitiveBlockLayout;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;

/** Compact location of one StringTable entry inside a PrimitiveBlock. */
struct StringRef
{
    /// Byte offset from the start of `PrimitiveBlockLayout.raw`.
    uint offset;
    /// Number of bytes in the StringTable entry.
    uint length;
}

/**
 * O(1) indexed borrowed view of the merged PrimitiveBlock StringTable.
 *
 * `entries` borrows caller-owned index storage supplied to
 * `buildStringTableView`; `rawBlock` borrows the original PrimitiveBlock.
 * Neither may be invalidated while this view is in use.
 */
struct StringTableView
{
    /// Complete serialized PrimitiveBlock containing all referenced bytes.
    const(ubyte)[] rawBlock;
    /// Compact offsets/lengths for merged StringTable entries.
    const(StringRef)[] entries;

    /** Returns the number of indexed strings. */
    pragma(inline, true)
    @property size_t length() const @safe pure nothrow @nogc
    {
        return entries.length;
    }

    /** Returns `true` when the table contains no entries. */
    @property bool empty() const @safe pure nothrow @nogc
    {
        return entries.length == 0;
    }

    /**
     * Borrow one StringTable entry by numeric string ID.
     *
     * Params:
     *   index = Zero-based OSMPBF string-table ID.
     *   value = Receives the borrowed raw bytes on success.
     *
     * Returns:
     *   `true` for an in-range valid StringRef; `false` otherwise.
     */
    pragma(inline, true)
    bool get(size_t index, out const(ubyte)[] value) const
        @safe nothrow @nogc
    {
        if (index >= entries.length)
        {
            value = null;
            return false;
        }

        const item = entries[index];
        const start = cast(size_t)item.offset;
        const finish = start + cast(size_t)item.length;
        if (finish < start || finish > rawBlock.length)
        {
            value = null;
            return false;
        }

        value = rawBlock[start .. finish];
        return true;
    }
}

/**
 * Build an indexed zero-copy StringTable view into caller-owned workspace.
 *
 * The supplied layout must come from `decodePrimitiveBlockLayout`. Workspace
 * must contain at least `layout.stringCount` elements. The function rescans
 * only StringTable fields and fills one compact `StringRef` per merged `s`
 * occurrence in protobuf wire order.
 *
 * Params:
 *   layout = Validated PrimitiveBlock first-pass layout.
 *   workspace = Caller-owned index storage, typically from a block arena.
 *   table = Receives the indexed borrowed view on success.
 *   status = Receives success, insufficient workspace, or a defensive wire
 *            failure if the supplied layout is inconsistent.
 *
 * Returns:
 *   `true` when every StringTable entry was indexed; `false` otherwise.
 */
bool buildStringTableView(
    ref const PrimitiveBlockLayout layout,
    StringRef[] workspace,
    out StringTableView table,
    out PbfStatus status)
    @safe nothrow @nogc
{
    table = StringTableView.init;

    if (workspace.length < layout.stringCount)
    {
        status = PbfStatus.failure(PbfError.stringTableWorkspaceTooSmall, 0, 1);
        return false;
    }

    auto cursor = WireCursor(layout.raw);
    size_t used;

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromPrimitiveBlockWire(wire);
            return false;
        }

        if (field.number == 1 && field.wireType == WireType.lengthDelimited)
        {
            const(ubyte)[] payload;
            if (!readLengthDelimited(cursor, field.number, payload, wire))
            {
                status = PbfStatus.fromPrimitiveBlockWire(wire);
                return false;
            }

            const payloadOffset = cursor.offset - payload.length;
            if (!indexStringTable(
                payload,
                payloadOffset,
                workspace,
                used,
                status))
                return false;
            continue;
        }

        if (!skipFieldValue(cursor, field, wire))
        {
            status = PbfStatus.fromPrimitiveBlockWire(wire);
            return false;
        }
    }

    if (used != layout.stringCount)
    {
        status = PbfStatus.failure(PbfError.stringTableCountMismatch, 0, 1);
        return false;
    }

    table.rawBlock = layout.raw;
    table.entries = workspace[0 .. used];
    status = PbfStatus.init;
    return true;
}

private bool indexStringTable(
    const(ubyte)[] payload,
    size_t baseOffset,
    StringRef[] workspace,
    ref size_t used,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto cursor = WireCursor(payload);

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromStringTableWire(wire, baseOffset);
            return false;
        }

        if (field.number == 1 && field.wireType == WireType.lengthDelimited)
        {
            const(ubyte)[] value;
            if (!readLengthDelimited(cursor, field.number, value, wire))
            {
                status = PbfStatus.fromStringTableWire(wire, baseOffset);
                return false;
            }

            if (used >= workspace.length)
            {
                status = PbfStatus.failure(PbfError.stringTableWorkspaceTooSmall, 0, 1);
                return false;
            }

            const valueOffset = baseOffset + cursor.offset - value.length;
            if (valueOffset > uint.max || value.length > uint.max)
            {
                status = PbfStatus.failure(PbfError.primitiveBlockTooLarge, valueOffset, 1);
                return false;
            }

            workspace[used++] = StringRef(
                cast(uint)valueOffset,
                cast(uint)value.length);
            continue;
        }

        if (!skipFieldValue(cursor, field, wire))
        {
            status = PbfStatus.fromStringTableWire(wire, baseOffset);
            return false;
        }
    }

    status = PbfStatus.init;
    return true;
}

unittest
{
    const(ubyte)[] input = [
        0x0a, 0x05, 0x0a, 0x00, 0x0a, 0x01, 'a',
        0x12, 0x00,
        0x0a, 0x03, 0x0a, 0x01, 'b',
    ];

    PrimitiveBlockLayout layout;
    PbfStatus status;
    import osm.io.pbf.primitive_block : decodePrimitiveBlockLayout;
    assert(decodePrimitiveBlockLayout(input, layout, status));
    assert(layout.stringCount == 3);

    StringRef[3] refs;
    StringTableView table;
    assert(buildStringTableView(layout, refs[], table, status));
    assert(table.length == 3);

    const(ubyte)[] value;
    assert(table.get(0, value) && value.length == 0);
    assert(table.get(1, value));
    const(ubyte)[] a = ['a'];
    assert(value == a);
    assert(table.get(2, value));
    const(ubyte)[] b = ['b'];
    assert(value == b);
    assert(!table.get(3, value));
}

unittest
{
    const(ubyte)[] input = [0x0a, 0x02, 0x0a, 0x00];
    PrimitiveBlockLayout layout;
    PbfStatus status;
    import osm.io.pbf.primitive_block : decodePrimitiveBlockLayout;
    assert(decodePrimitiveBlockLayout(input, layout, status));

    StringRef[] none;
    StringTableView table;
    assert(!buildStringTableView(layout, none, table, status));
    assert(status.error == PbfError.stringTableWorkspaceTooSmall);
}
