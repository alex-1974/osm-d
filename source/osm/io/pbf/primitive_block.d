/**
 * First-pass zero-copy layout decoder for OSMPBF `PrimitiveBlock` messages.
 *
 * The decoder extracts only the block-level structure required by later hot
 * paths: StringTable occurrence/count information, borrowed PrimitiveGroup
 * payloads, coordinate/date granularities, and coordinate offsets. Primitive
 * groups themselves remain opaque at this stage.
 *
 * Singular protobuf scalar fields follow last-one-wins semantics. Repeated
 * occurrences of the required singular `stringtable` message are merged as
 * protobuf message fields, which for `StringTable.s` means concatenating the
 * repeated string entries in wire occurrence order.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.primitive_block;

import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.limits : maxUncompressedBlobSize;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;
import osm.wire.varint : readVarint64;

/** One borrowed serialized `PrimitiveGroup` occurrence and its wire offset. */
struct PrimitiveGroupRef
{
    /// Complete serialized PrimitiveGroup payload, excluding key and length.
    const(ubyte)[] bytes;
    /// Offset of the field key within the serialized PrimitiveBlock.
    size_t offset;
}

/**
 * Allocation-free input range over serialized PrimitiveGroup occurrences.
 *
 * The parent block has already been structurally validated. The range rescans
 * only the top-level PrimitiveBlock and yields field-2 length-delimited
 * payloads in original wire order.
 */
struct PrimitiveGroupRange
{
private:
    WireCursor _cursor;
    PrimitiveGroupRef _front;
    bool _hasFront;

    this(const(ubyte)[] raw) @safe nothrow @nogc
    {
        _cursor = WireCursor(raw);
        advance();
    }

    void advance() @safe nothrow @nogc
    {
        _hasFront = false;
        _front = PrimitiveGroupRef.init;

        while (!_cursor.empty)
        {
            FieldHeader field;
            WireStatus wire;
            if (!readFieldHeader(_cursor, field, wire))
            {
                _cursor = WireCursor(null);
                return;
            }

            if (field.number == 2 && field.wireType == WireType.lengthDelimited)
            {
                const(ubyte)[] payload;
                if (!readLengthDelimited(_cursor, field.number, payload, wire))
                {
                    _cursor = WireCursor(null);
                    return;
                }

                _front = PrimitiveGroupRef(payload, field.offset);
                _hasFront = true;
                return;
            }

            if (!skipFieldValue(_cursor, field, wire))
            {
                _cursor = WireCursor(null);
                return;
            }
        }
    }

public:
    /** Returns `true` after all PrimitiveGroup occurrences are consumed. */
    @property bool empty() const @safe pure nothrow @nogc
    {
        return !_hasFront;
    }

    /** Returns the current borrowed PrimitiveGroup occurrence. */
    @property PrimitiveGroupRef front() const @safe pure nothrow @nogc
    {
        return _front;
    }

    /** Advance to the next PrimitiveGroup occurrence. */
    void popFront() @safe nothrow @nogc
    {
        if (_hasFront)
            advance();
    }
}

/**
 * Cheap first-pass layout of one structurally valid OSMPBF PrimitiveBlock.
 *
 * `raw` remains authoritative. Scalar presence flags distinguish an absent
 * optional field from an explicitly encoded default value. `stringCount` is
 * the merged number of `StringTable.s` entries across all valid StringTable
 * message occurrences.
 */
struct PrimitiveBlockLayout
{
    /// Complete serialized PrimitiveBlock, including unknown fields.
    const(ubyte)[] raw;
    /// Coordinate granularity in nanodegrees; protobuf default is 100.
    int granularity = 100;
    /// Timestamp granularity in milliseconds; protobuf default is 1000.
    int dateGranularity = 1000;
    /// Latitude offset in nanodegrees; protobuf default is zero.
    long latOffset;
    /// Longitude offset in nanodegrees; protobuf default is zero.
    long lonOffset;
    /// Number of merged StringTable entries.
    size_t stringCount;
    /// Number of correctly encoded top-level StringTable message occurrences.
    size_t stringTableOccurrences;
    /// Number of correctly encoded PrimitiveGroup message occurrences.
    size_t primitiveGroupCount;
    /// Whether `granularity` occurred with the expected wire type.
    bool hasGranularity;
    /// Whether `date_granularity` occurred with the expected wire type.
    bool hasDateGranularity;
    /// Whether `lat_offset` occurred with the expected wire type.
    bool hasLatOffset;
    /// Whether `lon_offset` occurred with the expected wire type.
    bool hasLonOffset;

    /** Returns the PrimitiveGroup payloads in original wire order. */
    @property PrimitiveGroupRange primitiveGroups() const @safe nothrow @nogc
    {
        return PrimitiveGroupRange(raw);
    }
}

private struct StringTableScanState
{
    size_t count;
    size_t firstEntryOffset;
    bool sawEntry;
    bool firstEntryEmpty;
}

/**
 * Decode and validate one complete serialized OSMPBF `PrimitiveBlock` layout.
 *
 * StringTable messages are structurally scanned so their merged entry count is
 * known without allocating. The required table must occur at least once, must
 * contain at least one `s` entry, and merged string index zero must be empty as
 * required by the OSMPBF schema contract. PrimitiveGroup payloads are not
 * interpreted yet.
 *
 * Params:
 *   input = Complete uncompressed PrimitiveBlock payload bytes.
 *   layout = Receives the zero-copy first-pass layout on success.
 *   status = Receives success or a precise structural/wire failure.
 *
 * Returns:
 *   `true` when the block-level structure and StringTable are valid; `false`
 *   otherwise.
 */
bool decodePrimitiveBlockLayout(
    const(ubyte)[] input,
    out PrimitiveBlockLayout layout,
    out PbfStatus status)
    @safe nothrow @nogc
{
    layout = PrimitiveBlockLayout.init;
    layout.raw = input;

    if (input.length >= maxUncompressedBlobSize)
    {
        status = PbfStatus.failure(PbfError.primitiveBlockTooLarge, 0);
        return false;
    }

    auto cursor = WireCursor(input);
    StringTableScanState strings;
    size_t firstStringTableOffset;

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
            if (!scanStringTable(payload, payloadOffset, strings, status))
                return false;

            if (layout.stringTableOccurrences == 0)
                firstStringTableOffset = field.offset;
            ++layout.stringTableOccurrences;
            continue;
        }

        if (field.number == 2 && field.wireType == WireType.lengthDelimited)
        {
            const(ubyte)[] payload;
            if (!readLengthDelimited(cursor, field.number, payload, wire))
            {
                status = PbfStatus.fromPrimitiveBlockWire(wire);
                return false;
            }

            ++layout.primitiveGroupCount;
            continue;
        }

        if (field.number == 17 && field.wireType == WireType.varint)
        {
            ulong value;
            if (!readVarint64(cursor, value, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = field.number;
                status = PbfStatus.fromPrimitiveBlockWire(wire);
                return false;
            }
            layout.granularity = decodeInt32(value);
            layout.hasGranularity = true;
            continue;
        }

        if (field.number == 18 && field.wireType == WireType.varint)
        {
            ulong value;
            if (!readVarint64(cursor, value, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = field.number;
                status = PbfStatus.fromPrimitiveBlockWire(wire);
                return false;
            }
            layout.dateGranularity = decodeInt32(value);
            layout.hasDateGranularity = true;
            continue;
        }

        if (field.number == 19 && field.wireType == WireType.varint)
        {
            ulong value;
            if (!readVarint64(cursor, value, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = field.number;
                status = PbfStatus.fromPrimitiveBlockWire(wire);
                return false;
            }
            layout.latOffset = cast(long)value;
            layout.hasLatOffset = true;
            continue;
        }

        if (field.number == 20 && field.wireType == WireType.varint)
        {
            ulong value;
            if (!readVarint64(cursor, value, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = field.number;
                status = PbfStatus.fromPrimitiveBlockWire(wire);
                return false;
            }
            layout.lonOffset = cast(long)value;
            layout.hasLonOffset = true;
            continue;
        }

        if (!skipFieldValue(cursor, field, wire))
        {
            status = PbfStatus.fromPrimitiveBlockWire(wire);
            return false;
        }
    }

    if (layout.stringTableOccurrences == 0)
    {
        status = PbfStatus.failure(PbfError.missingPrimitiveBlockStringTable, 0, 1);
        return false;
    }

    if (!strings.sawEntry)
    {
        status = PbfStatus.failure(
            PbfError.missingStringTableZeroEntry,
            firstStringTableOffset,
            1);
        return false;
    }

    if (!strings.firstEntryEmpty)
    {
        status = PbfStatus.failure(
            PbfError.nonEmptyStringTableZeroEntry,
            strings.firstEntryOffset,
            1);
        return false;
    }

    layout.stringCount = strings.count;
    status = PbfStatus.init;
    return true;
}

private bool scanStringTable(
    const(ubyte)[] payload,
    size_t baseOffset,
    ref StringTableScanState state,
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

            if (!state.sawEntry)
            {
                state.sawEntry = true;
                state.firstEntryEmpty = value.length == 0;
                state.firstEntryOffset = baseOffset + field.offset;
            }
            ++state.count;
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

private int decodeInt32(ulong value) @safe pure nothrow @nogc
{
    return cast(int)cast(uint)value;
}

unittest
{
    // StringTable: "", "highway", "residential"; one empty group.
    const(ubyte)[] input = [
        0x0a, 0x18,
        0x0a, 0x00,
        0x0a, 0x07, 'h', 'i', 'g', 'h', 'w', 'a', 'y',
        0x0a, 0x0b, 'r', 'e', 's', 'i', 'd', 'e', 'n', 't', 'i', 'a', 'l',
        0x12, 0x00,
        0x88, 0x01, 0x64,
        0x90, 0x01, 0xe8, 0x07,
    ];

    PrimitiveBlockLayout layout;
    PbfStatus status;
    assert(decodePrimitiveBlockLayout(input, layout, status));
    assert(status.ok);
    assert(layout.stringCount == 3);
    assert(layout.stringTableOccurrences == 1);
    assert(layout.primitiveGroupCount == 1);
    assert(layout.granularity == 100 && layout.hasGranularity);
    assert(layout.dateGranularity == 1000 && layout.hasDateGranularity);

    auto groups = layout.primitiveGroups;
    assert(!groups.empty);
    assert(groups.front.bytes.length == 0);
    groups.popFront();
    assert(groups.empty);
}

unittest
{
    // Two StringTable message occurrences merge; scalar duplicates use last one.
    const(ubyte)[] input = [
        0x88, 0x01, 0x32,             // granularity = 50
        0x0a, 0x05, 0x0a, 0x00, 0x0a, 0x01, 'a',
        0x12, 0x01, 0x08,             // opaque PrimitiveGroup
        0x0a, 0x03, 0x0a, 0x01, 'b',
        0x88, 0x01, 0xc8, 0x01,       // granularity = 200
    ];

    PrimitiveBlockLayout layout;
    PbfStatus status;
    assert(decodePrimitiveBlockLayout(input, layout, status));
    assert(layout.stringTableOccurrences == 2);
    assert(layout.stringCount == 3);
    assert(layout.granularity == 200);
    assert(layout.primitiveGroupCount == 1);
}

unittest
{
    PrimitiveBlockLayout layout;
    PbfStatus status;

    const(ubyte)[] missing = [0x12, 0x00];
    assert(!decodePrimitiveBlockLayout(missing, layout, status));
    assert(status.error == PbfError.missingPrimitiveBlockStringTable);

    const(ubyte)[] nonEmptyZero = [0x0a, 0x03, 0x0a, 0x01, 'x'];
    assert(!decodePrimitiveBlockLayout(nonEmptyZero, layout, status));
    assert(status.error == PbfError.nonEmptyStringTableZeroEntry);

    const(ubyte)[] noEntries = [0x0a, 0x00];
    assert(!decodePrimitiveBlockLayout(noEntries, layout, status));
    assert(status.error == PbfError.missingStringTableZeroEntry);

    const(ubyte)[] malformedTable = [0x0a, 0x02, 0x0a, 0x02];
    assert(!decodePrimitiveBlockLayout(malformedTable, layout, status));
    assert(status.error == PbfError.invalidStringTableWire);
}

unittest
{
    // Absent optional scalars retain protobuf defaults and no presence bit.
    const(ubyte)[] input = [0x0a, 0x02, 0x0a, 0x00];
    PrimitiveBlockLayout layout;
    PbfStatus status;
    assert(decodePrimitiveBlockLayout(input, layout, status));
    assert(layout.granularity == 100 && !layout.hasGranularity);
    assert(layout.dateGranularity == 1000 && !layout.hasDateGranularity);
    assert(layout.latOffset == 0 && !layout.hasLatOffset);
    assert(layout.lonOffset == 0 && !layout.hasLonOffset);
}

unittest
{
    // int64 protobuf values retain their exact two's-complement interpretation.
    const(ubyte)[] input = [
        0x0a, 0x02, 0x0a, 0x00,
        0x98, 0x01,
        0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
        0xa0, 0x01, 0x01,
    ];
    PrimitiveBlockLayout layout;
    PbfStatus status;
    assert(decodePrimitiveBlockLayout(input, layout, status));
    assert(layout.latOffset == -1 && layout.hasLatOffset);
    assert(layout.lonOffset == 1 && layout.hasLonOffset);
}
