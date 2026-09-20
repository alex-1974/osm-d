/**
 * Allocation-free decoding of normal OSMPBF element `keys`/`vals` tags.
 *
 * Node, Way, and Relation use identical parallel repeated uint32 arrays for
 * tag StringTable IDs. This module accepts packed, unpacked, repeated, and
 * interleaved protobuf occurrences, validates the complete logical arrays
 * before exposure, and returns borrowed ranges without materializing tags.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-13
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.tags;

import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.string_table : StringTableView;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;
import osm.wire.varint : readVarint32;

/** One ordered borrowed tag from normal element `keys`/`vals` arrays. */
struct TagView
{
    /// Validated non-zero StringTable ID of the tag key.
    uint keySid;
    /// Validated non-zero StringTable ID of the tag value.
    uint valueSid;
    /// Borrowed raw key bytes.
    const(ubyte)[] key;
    /// Borrowed raw value bytes.
    const(ubyte)[] value;
}

/** Shape validated for one normal element's parallel tag arrays. */
struct TagValidationSummary
{
    /// Logical key count after concatenating packed/unpacked occurrences.
    size_t keyCount;
    /// Logical value count after concatenating packed/unpacked occurrences.
    size_t valueCount;

    /** Number of validated key/value pairs. */
    @property size_t tagCount() const @safe pure nothrow @nogc
    {
        return keyCount;
    }
}

/** Borrowed input range over one normal element's validated ordered tags. */
struct TagRange
{
private:
    UInt32FieldCursor _keys;
    UInt32FieldCursor _vals;
    StringTableView _table;
    TagView _front;
    size_t _remaining;

public:
    /** Returns `true` when no tag remains. */
    pragma(inline, true)
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _remaining == 0;
    }

    /** Returns the number of tags not yet consumed. */
    pragma(inline, true)
    @property size_t length() const @safe pure nothrow @nogc
    {
        return _remaining;
    }

    /** Return the current validated tag. The range must be non-empty. */
    pragma(inline, true)
    @property TagView front() const @safe nothrow @nogc
    in (!empty)
    {
        return _front;
    }

    /** Advance to the next validated tag. */
    pragma(inline, true)
    void popFront() @safe nothrow @nogc
    in (!empty)
    {
        --_remaining;
        if (_remaining == 0)
        {
            _front = TagView.init;
            return;
        }

        PbfStatus ignored;
        TagView next;
        if (!decodeValidatedPair(_keys, _vals, _table, next, ignored))
        {
            // The backing bytes were completely prevalidated and must remain unchanged.
            _remaining = 0;
            _front = TagView.init;
            return;
        }
        _front = next;
    }
}

/**
 * Validate complete parallel `keys` and `vals` arrays for one element message.
 *
 * Index zero is rejected because the OSMPBF StringTable reserves it as blank
 * and unused. Every other ID must resolve in the supplied StringTable, and the
 * logical key/value counts must be equal.
 */
bool validateTags(
    const(ubyte)[] input,
    size_t baseOffset,
    StringTableView table,
    out TagValidationSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    summary = TagValidationSummary.init;

    auto keys = UInt32FieldCursor(input, baseOffset, 2);
    auto vals = UInt32FieldCursor(input, baseOffset, 3);

    while (true)
    {
        uint keySid;
        uint valueSid;
        bool hasKey;
        bool hasValue;

        if (!keys.next(keySid, hasKey, status))
            return false;
        if (!vals.next(valueSid, hasValue, status))
            return false;

        if (hasKey)
            ++summary.keyCount;
        if (hasValue)
            ++summary.valueCount;

        if (hasKey != hasValue)
        {
            status = PbfStatus.failure(
                PbfError.tagColumnLengthMismatch,
                hasKey ? keys.lastValueOffset : vals.lastValueOffset,
                hasKey ? 2 : 3);
            return false;
        }

        if (!hasKey)
            break;

        if (!validateStringId(keySid, keys.lastValueOffset, table, 2, status) ||
            !validateStringId(valueSid, vals.lastValueOffset, table, 3, status))
            return false;
    }

    status = PbfStatus.init;
    return true;
}

/**
 * Build a borrowed TagRange from an already validated element message.
 *
 * `summary` must come from `validateTags` for the same bytes, unchanged since
 * validation, and the same StringTable.
 */
bool buildTagRange(
    const(ubyte)[] input,
    size_t baseOffset,
    StringTableView table,
    TagValidationSummary summary,
    out TagRange range,
    out PbfStatus status)
    @safe nothrow @nogc
{
    range = TagRange.init;
    range._keys = UInt32FieldCursor(input, baseOffset, 2);
    range._vals = UInt32FieldCursor(input, baseOffset, 3);
    range._table = table;
    range._remaining = summary.tagCount;

    if (range._remaining != 0)
    {
        if (!decodeValidatedPair(
            range._keys,
            range._vals,
            table,
            range._front,
            status))
        {
            range = TagRange.init;
            return false;
        }
    }

    status = PbfStatus.init;
    return true;
}

pragma(inline, true)
private bool validateStringId(
    uint sid,
    size_t offset,
    StringTableView table,
    uint fieldNumber,
    out PbfStatus status)
    @safe nothrow @nogc
{
    if (sid == 0)
    {
        status = PbfStatus.failure(
            PbfError.invalidTagStringId,
            offset,
            fieldNumber);
        return false;
    }

    if (cast(size_t)sid >= table.length)
    {
        status = PbfStatus.failure(
            PbfError.tagStringIdOutOfRange,
            offset,
            fieldNumber);
        return false;
    }

    status = PbfStatus.init;
    return true;
}

pragma(inline, true)
private bool decodeValidatedPair(
    ref UInt32FieldCursor keys,
    ref UInt32FieldCursor vals,
    StringTableView table,
    out TagView tag,
    out PbfStatus status)
    @safe nothrow @nogc
{
    tag = TagView.init;

    uint keySid;
    uint valueSid;
    bool hasKey;
    bool hasValue;

    if (!keys.next(keySid, hasKey, status) ||
        !vals.next(valueSid, hasValue, status))
        return false;

    if (!hasKey || !hasValue)
    {
        status = PbfStatus.failure(PbfError.tagColumnLengthMismatch, 0, 2);
        return false;
    }

    const(ubyte)[] key;
    const(ubyte)[] value;
    if (!table.get(keySid, key))
    {
        status = PbfStatus.failure(
            PbfError.tagStringIdOutOfRange,
            keys.lastValueOffset,
            2);
        return false;
    }
    if (!table.get(valueSid, value))
    {
        status = PbfStatus.failure(
            PbfError.tagStringIdOutOfRange,
            vals.lastValueOffset,
            3);
        return false;
    }

    tag = TagView(keySid, valueSid, key, value);
    status = PbfStatus.init;
    return true;
}

/** Logical cursor over one repeated uint32 field in a protobuf message. */
private struct UInt32FieldCursor
{
private:
    WireCursor _message;
    WireCursor _packed;
    size_t _baseOffset;
    size_t _packedBase;
    size_t _lastValueOffset;
    uint _fieldNumber;

public:
    this(
        const(ubyte)[] input,
        size_t baseOffset,
        uint fieldNumber)
        @safe nothrow @nogc
    {
        _message = WireCursor(input);
        _baseOffset = baseOffset;
        _fieldNumber = fieldNumber;
    }

    @property size_t lastValueOffset() const @safe pure nothrow @nogc
    {
        return _lastValueOffset;
    }

    pragma(inline, true)
    bool next(out uint value, out bool hasValue, out PbfStatus status)
        @safe nothrow @nogc
    {
        value = 0;
        hasValue = false;

        while (true)
        {
            if (!_packed.empty)
            {
                _lastValueOffset = _packedBase + _packed.offset;
                WireStatus wire;
                if (!readVarint32(_packed, value, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = _fieldNumber;
                    status = PbfStatus.fromTagWire(wire, _packedBase);
                    return false;
                }

                hasValue = true;
                status = PbfStatus.init;
                return true;
            }

            while (!_message.empty)
            {
                FieldHeader field;
                WireStatus wire;
                if (!readFieldHeader(_message, field, wire))
                {
                    status = PbfStatus.fromTagWire(wire, _baseOffset);
                    return false;
                }

                if (field.number == _fieldNumber &&
                    field.wireType == WireType.varint)
                {
                    _lastValueOffset = _baseOffset + _message.offset;
                    if (!readVarint32(_message, value, wire))
                    {
                        if (wire.fieldNumber == 0)
                            wire.fieldNumber = field.number;
                        status = PbfStatus.fromTagWire(wire, _baseOffset);
                        return false;
                    }

                    hasValue = true;
                    status = PbfStatus.init;
                    return true;
                }

                if (field.number == _fieldNumber &&
                    field.wireType == WireType.lengthDelimited)
                {
                    const(ubyte)[] packed;
                    if (!readLengthDelimited(_message, field.number, packed, wire))
                    {
                        status = PbfStatus.fromTagWire(wire, _baseOffset);
                        return false;
                    }

                    _packedBase =
                        _baseOffset + _message.offset - packed.length;
                    _packed = WireCursor(packed);

                    if (!_packed.empty)
                        break;

                    // Empty packed occurrences are legal and contribute no values.
                    continue;
                }

                if (!skipFieldValue(_message, field, wire))
                {
                    status = PbfStatus.fromTagWire(wire, _baseOffset);
                    return false;
                }
            }

            if (!_packed.empty)
                continue;

            if (_message.empty)
            {
                status = PbfStatus.init;
                return true;
            }
        }
    }
}

unittest
{
    import osm.io.pbf.string_table : StringRef;

    // keys: packed [1], unpacked 3; vals: unpacked 2, packed [4].
    const(ubyte)[] element = [
        0x12, 0x01, 0x01,
        0x18, 0x02,
        0x10, 0x03,
        0x1a, 0x01, 0x04,
    ];

    const(ubyte)[] strings = [0, 'a', '1', 'b', '2'];
    StringRef[5] refs = [
        StringRef(0, 0),
        StringRef(1, 1),
        StringRef(2, 1),
        StringRef(3, 1),
        StringRef(4, 1),
    ];
    StringTableView table = StringTableView(strings, refs[]);

    TagValidationSummary summary;
    PbfStatus status;
    assert(validateTags(element, 100, table, summary, status));
    assert(summary.keyCount == 2);
    assert(summary.valueCount == 2);
    assert(summary.tagCount == 2);

    TagRange tags;
    assert(buildTagRange(element, 100, table, summary, tags, status));
    assert(tags.length == 2);

    const(ubyte)[] a = ['a'];
    const(ubyte)[] b = ['b'];
    assert(tags.front.keySid == 1 && tags.front.valueSid == 2);
    assert(tags.front.key == a);
    tags.popFront();
    assert(tags.front.keySid == 3 && tags.front.valueSid == 4);
    assert(tags.front.key == b);
    tags.popFront();
    assert(tags.empty);
}

unittest
{
    import osm.io.pbf.string_table : StringRef;

    const(ubyte)[] strings = [0, 'k', 'v'];
    StringRef[3] refs = [
        StringRef(0, 0),
        StringRef(1, 1),
        StringRef(2, 1),
    ];
    StringTableView table = StringTableView(strings, refs[]);

    TagValidationSummary summary;
    PbfStatus status;

    const(ubyte)[] mismatch = [
        0x12, 0x02, 0x01, 0x01,
        0x1a, 0x01, 0x02,
    ];
    assert(!validateTags(mismatch, 0, table, summary, status));
    assert(status.error == PbfError.tagColumnLengthMismatch);

    const(ubyte)[] zero = [0x12, 0x01, 0x00, 0x1a, 0x01, 0x02];
    assert(!validateTags(zero, 0, table, summary, status));
    assert(status.error == PbfError.invalidTagStringId);

    const(ubyte)[] outOfRange = [0x12, 0x01, 0x03, 0x1a, 0x01, 0x02];
    assert(!validateTags(outOfRange, 0, table, summary, status));
    assert(status.error == PbfError.tagStringIdOutOfRange);
}


unittest
{
    import osm.io.pbf.string_table : StringRef;

    // Legal over-wide protobuf varints for uint32 are truncated to their low
    // 32 bits before semantic StringTable lookup.
    const(ubyte)[] element = [
        0x10, 0x81, 0x80, 0x80, 0x80, 0x10, // 2^32 + 1 -> uint32(1)
        0x18, 0x82, 0x80, 0x80, 0x80, 0x10, // 2^32 + 2 -> uint32(2)
    ];

    const(ubyte)[] strings = [0, 'k', 'v'];
    StringRef[3] refs = [
        StringRef(0, 0),
        StringRef(1, 1),
        StringRef(2, 1),
    ];
    StringTableView table = StringTableView(strings, refs[]);

    TagValidationSummary summary;
    PbfStatus status;
    assert(validateTags(element, 0, table, summary, status));
    assert(summary.tagCount == 1);

    TagRange tags;
    assert(buildTagRange(element, 0, table, summary, tags, status));
    assert(tags.length == 1);
    assert(tags.front.keySid == 1);
    assert(tags.front.valueSid == 2);
}
