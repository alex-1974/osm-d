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

import osm.view.tag : TagView;
import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.string_table : StringTableView;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    readLengthDelimitedCursor,
    skipFieldValue;
import osm.wire.varint : readVarint32;

/** Shape validated for one normal element's parallel tag arrays. */
package(osm)
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


private struct DecodedTagPair
{
    uint keySid;
    uint valueSid;
    size_t keyOffset;
    size_t valueOffset;
}

/** Borrowed input range over one normal element's validated ordered tags. */
struct TagRange
{
private:
    UInt32FieldCursor _keys;
    UInt32FieldCursor _vals;
    StringTableView _table;
    TagView _front;
    uint _frontKeySid;
    uint _frontValueSid;
    size_t _remaining;

public:
    /** Returns `true` when no tag remains. */
    pragma(inline, true)
    @property bool empty() const scope @safe pure nothrow @nogc
    {
        return _remaining == 0;
    }

    /** Returns the number of tags not yet consumed. */
    pragma(inline, true)
    @property size_t length() const scope @safe pure nothrow @nogc
    {
        return _remaining;
    }

    /** Return the current validated tag. The range must be non-empty. */
    pragma(inline, true)
    @property TagView front() const return scope @safe nothrow @nogc
    in (!empty)
    {
        return _front;
    }

package(osm):
    /** Current PBF StringTable ID of the key, for codec diagnostics/benchmarks. */
    pragma(inline, true)
    @property uint frontKeyStringId() const scope @safe pure nothrow @nogc
    in (!empty)
    {
        return _frontKeySid;
    }

    /** Current PBF StringTable ID of the value, for codec diagnostics/benchmarks. */
    pragma(inline, true)
    @property uint frontValueStringId() const scope @safe pure nothrow @nogc
    in (!empty)
    {
        return _frontValueSid;
    }

public:
    /** Advance to the next validated tag. */
    pragma(inline, true)
    void popFront() scope @safe nothrow @nogc
    in (!empty)
    {
        --_remaining;
        if (_remaining == 0)
        {
            _front = TagView.init;
            _frontKeySid = 0;
            _frontValueSid = 0;
            return;
        }

        PbfStatus ignored;
        if (!advance(ignored))
        {
            // The backing bytes were completely prevalidated and must remain unchanged.
            _remaining = 0;
            _front = TagView.init;
            _frontKeySid = 0;
            _frontValueSid = 0;
        }
    }

private:
    pragma(inline, true)
    bool advance(out PbfStatus status) scope @safe nothrow @nogc
    {
        DecodedTagPair decoded;
        if (!decodeValidatedPairScalars(
                _keys,
                _vals,
                decoded,
                status))
            return false;

        if (cast(size_t)decoded.keySid >= _table.entries.length)
        {
            status = PbfStatus.failure(
                PbfError.tagStringIdOutOfRange,
                decoded.keyOffset,
                2);
            return false;
        }
        if (cast(size_t)decoded.valueSid >= _table.entries.length)
        {
            status = PbfStatus.failure(
                PbfError.tagStringIdOutOfRange,
                decoded.valueOffset,
                3);
            return false;
        }

        const keyRef = _table.entries[cast(size_t)decoded.keySid];
        const valueRef = _table.entries[cast(size_t)decoded.valueSid];

        const keyStart = cast(size_t)keyRef.offset;
        const keyFinish = keyStart + cast(size_t)keyRef.length;
        const valueStart = cast(size_t)valueRef.offset;
        const valueFinish = valueStart + cast(size_t)valueRef.length;

        if (keyFinish < keyStart || keyFinish > _table.rawBlock.length)
        {
            status = PbfStatus.failure(
                PbfError.tagStringIdOutOfRange,
                decoded.keyOffset,
                2);
            return false;
        }
        if (valueFinish < valueStart || valueFinish > _table.rawBlock.length)
        {
            status = PbfStatus.failure(
                PbfError.tagStringIdOutOfRange,
                decoded.valueOffset,
                3);
            return false;
        }

        _frontKeySid = decoded.keySid;
        _frontValueSid = decoded.valueSid;
        _front = TagView(
            _table.rawBlock[keyStart .. keyFinish],
            _table.rawBlock[valueStart .. valueFinish]);
        status = PbfStatus.init;
        return true;
    }
}

/**
 * Validate complete parallel `keys` and `vals` arrays for one element message.
 *
 * Index zero is rejected because the OSMPBF StringTable reserves it as blank
 * and unused. Every other ID must resolve in the supplied StringTable, and the
 * logical key/value counts must be equal.
 */
package(osm)
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
package(osm)
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
        if (!range.advance(status))
        {
            range = TagRange.init;
            return false;
        }
    }

    status = PbfStatus.init;
    return true;
}

/**
 * Build a borrowed TagRange directly from prevalidated canonical packed
 * key/value payloads.
 *
 * This is the no-search counterpart of `buildTagRange`. The supplied summary
 * and payloads must describe the same immutable element bytes that were
 * completely semantically validated before observable emission.
 */
package(osm)
bool buildPrevalidatedPackedTagRange(
    const(ubyte)[] keyPayload,
    size_t keyPayloadBase,
    const(ubyte)[] valuePayload,
    size_t valuePayloadBase,
    StringTableView table,
    TagValidationSummary summary,
    out TagRange range,
    out PbfStatus status)
    @safe nothrow @nogc
{
    range = TagRange.init;
    range._keys = UInt32FieldCursor.fromPrevalidatedPacked(
        keyPayload,
        keyPayloadBase,
        2);
    range._vals = UInt32FieldCursor.fromPrevalidatedPacked(
        valuePayload,
        valuePayloadBase,
        3);
    range._table = table;
    range._remaining = summary.tagCount;

    if (range._remaining != 0)
    {
        if (!range.advance(status))
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
private bool decodeValidatedPairScalars(
    scope ref UInt32FieldCursor keys,
    scope ref UInt32FieldCursor vals,
    out DecodedTagPair decoded,
    out PbfStatus status)
    @safe nothrow @nogc
{
    decoded = DecodedTagPair.init;

    bool hasKey;
    bool hasValue;

    if (!keys.next(decoded.keySid, hasKey, status) ||
        !vals.next(decoded.valueSid, hasValue, status))
        return false;

    if (!hasKey || !hasValue)
    {
        status = PbfStatus.failure(PbfError.tagColumnLengthMismatch, 0, 2);
        return false;
    }

    decoded.keyOffset = keys.lastValueOffset;
    decoded.valueOffset = vals.lastValueOffset;
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

    /**
     * Construct a cursor that starts directly in one already validated packed
     * repeated-field payload.
     *
     * No message-wide field search is performed. The caller must have proved
     * that this payload represents the complete logical repeated column.
     */
    static UInt32FieldCursor fromPrevalidatedPacked(
        const(ubyte)[] packed,
        size_t packedBase,
        uint fieldNumber)
        @safe nothrow @nogc
    {
        UInt32FieldCursor result;
        result._packed = WireCursor(packed);
        result._packedBase = packedBase;
        result._fieldNumber = fieldNumber;
        return result;
    }

    @property size_t lastValueOffset() const scope @safe pure nothrow @nogc
    {
        return _lastValueOffset;
    }

    pragma(inline, true)
    bool next(out uint value, out bool hasValue, out PbfStatus status)
        scope @safe nothrow @nogc
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
                    bool ok;
                    auto packed = readLengthDelimitedCursor(
                        _message,
                        field.number,
                        ok,
                        wire);
                    if (!ok)
                    {
                        status = PbfStatus.fromTagWire(wire, _baseOffset);
                        return false;
                    }

                    _packedBase =
                        _baseOffset + _message.offset - packed.remaining;
                    _packed = packed;

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
    assert(tags.frontKeyStringId == 1 && tags.frontValueStringId == 2);
    assert(tags.front.key == a);
    tags.popFront();
    assert(tags.frontKeyStringId == 3 && tags.frontValueStringId == 4);
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
    assert(tags.frontKeyStringId == 1);
    assert(tags.frontValueStringId == 2);
}


unittest
{
    import osm.io.pbf.string_table : StringRef;

    // Canonical prevalidated packed keys [1,3] and vals [2,4].
    const(ubyte)[] strings = [0, 'k', 'v', 'n', 'x'];
    StringRef[5] refs = [
        StringRef(0, 0),
        StringRef(1, 1),
        StringRef(2, 1),
        StringRef(3, 1),
        StringRef(4, 1),
    ];
    StringTableView table = StringTableView(strings, refs[]);

    const(ubyte)[] keys = [0x01, 0x03];
    const(ubyte)[] vals = [0x02, 0x04];

    TagValidationSummary summary;
    summary.keyCount = 2;
    summary.valueCount = 2;

    TagRange range;
    PbfStatus status;
    assert(buildPrevalidatedPackedTagRange(
        keys,
        100,
        vals,
        200,
        table,
        summary,
        range,
        status));
    assert(status.ok);
    assert(range.length == 2);

    assert(range.frontKeyStringId == 1);
    assert(range.frontValueStringId == 2);
    range.popFront();

    assert(range.frontKeyStringId == 3);
    assert(range.frontValueStringId == 4);
    range.popFront();

    assert(range.empty);
}

version (unittest)
{
    pragma(msg, "LAYOUT source/osm/io/pbf/tags.d: TagRange.sizeof=", TagRange.sizeof, " TagView.sizeof=", TagView.sizeof, " UInt32FieldCursor.sizeof=", UInt32FieldCursor.sizeof, " WireCursor.sizeof=", WireCursor.sizeof);
}

version (unittest)
{
    private enum CompactTagEncoding : ubyte
    {
        empty,
        regular,
        dense,
    }

    private struct CompactRepeatedFieldState
    {
        size_t messageOffset;
        size_t packedOffset;
        size_t packedEnd;
    }

    private struct CompactRegularTagState
    {
        const(ubyte)[] input;
        size_t baseOffset;
        CompactRepeatedFieldState keys;
        CompactRepeatedFieldState values;
    }

    private struct CompactDenseTagState
    {
        const(ubyte)[] group;
        size_t groupOffset;
        size_t denseOffset;
        size_t denseEnd;
        size_t packedOffset;
        size_t packedEnd;
        size_t denseBase;
        size_t packedBase;
    }

    private union CompactTagState
    {
        CompactRegularTagState regular;
        CompactDenseTagState dense;
    }

    private struct CompactTagRangeLayout
    {
        StringTableView table;
        TagView front;
        CompactTagState state;
        size_t remaining;
        uint frontKeySid;
        uint frontValueSid;
        CompactTagEncoding encoding;
    }

    private struct CompactNodeViewLayout
    {
        long id;
        long latNano;
        long lonNano;
        CompactTagRangeLayout tags;
        import osm.view.metadata : MetadataView;
        MetadataView metadata;
    }

    pragma(msg,
        "CANDIDATE CompactRepeatedFieldState.sizeof=",
        CompactRepeatedFieldState.sizeof,
        " CompactRegularTagState.sizeof=",
        CompactRegularTagState.sizeof,
        " CompactDenseTagState.sizeof=",
        CompactDenseTagState.sizeof,
        " CompactTagRangeLayout.sizeof=",
        CompactTagRangeLayout.sizeof,
        " CompactNodeViewLayout.sizeof=",
        CompactNodeViewLayout.sizeof);
}
