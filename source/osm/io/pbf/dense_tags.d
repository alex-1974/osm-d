/**
 * Zero-copy tag decoding for OSMPBF DenseNodes `keys_vals` streams.
 *
 * Dense tags are serialized for all nodes as one logical int32 stream. Each
 * node is terminated by string-table ID zero and all non-zero values occur as
 * ordered key/value pairs. This module validates that structure against the
 * validated DenseNodes node count and StringTable, then exposes per-node input
 * ranges without copying tag strings or materializing tag arrays.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.dense_tags;

import osm.view.tag : TagView;
import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.primitive_group : PrimitiveGroupLayout;
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
import osm.wire.varint : readVarint64;

/** Summary produced by a complete DenseNodes tag preflight. */
struct DenseTagValidationSummary
{
    /// Number of explicit node delimiters in a non-empty `keys_vals` stream.
    size_t nodeSegments;
    /// Number of validated key/value pairs in original serialized order.
    size_t tagCount;
    /// Number of logical int32 values consumed from packed/unpacked fields.
    size_t encodedValueCount;
}


private struct DecodedDenseTagPair
{
    uint keySid;
    uint valueSid;
    size_t keyOffset;
    size_t valueOffset;
}

/**
 * Borrowed input range over the tags belonging to one dense node.
 *
 * The range is created only after the complete DenseNodes tag stream has been
 * validated. Copies of the range are independent cursors but borrow the
 * PrimitiveGroup bytes, StringTable index storage, and PrimitiveBlock bytes.
 * Those owners must therefore outlive every range copy.
 */
struct DenseTagRange
{
private:
    KeysValsCursor _stream;
    StringTableView _table;
    TagView _front;
    uint _frontKeySid;
    uint _frontValueSid;
    size_t _remaining;

public:
    /** Returns `true` when no tag remains in this node. */
    pragma(inline, true)
    @property bool empty() const scope @safe pure nothrow @nogc
    {
        return _remaining == 0;
    }

    /** Returns the number of tags not yet consumed from this range. */
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
    /** Advance to the next validated tag in this node. */
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

        PbfStatus ignoredStatus;
        if (!advance(ignoredStatus))
        {
            // The complete stream was prevalidated and its backing is required
            // to remain unchanged while this range is used. Reaching this branch
            // therefore indicates an internal invariant failure rather than
            // hostile input.
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
        DecodedDenseTagPair decoded;
        if (!decodePrevalidatedPairScalars(_stream, decoded, status))
            return false;

        if (cast(size_t)decoded.keySid >= _table.entries.length)
        {
            status = PbfStatus.failure(
                PbfError.denseTagStringIdOutOfRange,
                decoded.keyOffset,
                10);
            return false;
        }
        if (cast(size_t)decoded.valueSid >= _table.entries.length)
        {
            status = PbfStatus.failure(
                PbfError.denseTagStringIdOutOfRange,
                decoded.valueOffset,
                10);
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
                PbfError.denseTagStringIdOutOfRange,
                decoded.keyOffset,
                10);
            return false;
        }
        if (valueFinish < valueStart || valueFinish > _table.rawBlock.length)
        {
            status = PbfStatus.failure(
                PbfError.denseTagStringIdOutOfRange,
                decoded.valueOffset,
                10);
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

    static bool fromValidated(
        KeysValsCursor stream,
        StringTableView table,
        size_t pairCount,
        out DenseTagRange range,
        out PbfStatus status)
        @safe nothrow @nogc
    {
        range = DenseTagRange.init;
        range._stream = stream;
        range._table = table;
        range._remaining = pairCount;

        if (pairCount != 0)
        {
            if (!range.advance(status))
            {
                range = DenseTagRange.init;
                return false;
            }
        }

        status = PbfStatus.init;
        return true;
    }
}

/**
 * Cursor that partitions one validated logical `keys_vals` stream by node.
 *
 * Construct this only after `validateDenseTags` succeeds for the same group
 * and StringTable. `nextNode` still performs defensive checks so misuse fails
 * with a structured status before returning an invalid range.
 */
struct DenseTagNodeCursor
{
private:
    KeysValsCursor _stream;
    StringTableView _table;
    size_t _remainingNodes;
    bool _implicitAllTagless;

public:
    /**
     * Initialize a node cursor over one validated PrimitiveGroup.
     *
     * Params:
     *   group = Validated PrimitiveGroup whose dense tag stream is traversed.
     *   table = Indexed StringTable from the same PrimitiveBlock.
     */
    this(ref const PrimitiveGroupLayout group, StringTableView table)
        @safe nothrow @nogc
    {
        _stream = KeysValsCursor(group.raw);
        _table = table;
        _remainingNodes = group.dense.nodeCount;
        _implicitAllTagless = group.dense.keysValsCount == 0;
    }

    /**
     * Return the borrowed tag range for the next dense node.
     *
     * An entirely empty logical `keys_vals` stream is the format-defined fast
     * path for an all-tagless DenseNodes message. Otherwise an explicit zero
     * delimiter must terminate every node, including tagless nodes.
     *
     * Params:
     *   tags = Receives the borrowed range for the next node.
     *   status = Receives success or a defensive structured failure.
     *
     * Returns:
     *   `true` when one node range was produced; `false` otherwise.
     */
    pragma(inline, true)
    bool nextNode(out DenseTagRange tags, out PbfStatus status)
        @safe nothrow @nogc
    {
        return nextNodeImpl!true(tags, status);
    }

package:
    /**
     * Return the next node range after complete DenseTags preflight.
     *
     * Preconditions:
     *   `validateDenseTags` succeeded for this same PrimitiveGroup/StringTable
     *   pair and the validated backing bytes have not changed since validation.
     *
     * This internal decode path retains wire, delimiter, pair-structure, and
     * node-count checks, but does not repeat StringTable-ID semantic validation
     * already proved by the complete preflight.
     */
    pragma(inline, true)
    bool nextPrevalidatedNode(out DenseTagRange tags, out PbfStatus status)
        @safe nothrow @nogc
    {
        return nextNodeImpl!false(tags, status);
    }

private:
    pragma(inline, true)
    bool nextNodeImpl(bool ValidateStringIds)(
        out DenseTagRange tags,
        out PbfStatus status)
        @safe nothrow @nogc
    {
        tags = DenseTagRange.init;

        if (_remainingNodes == 0)
        {
            status = PbfStatus.failure(PbfError.denseTagNodeCountMismatch, 0, 10);
            return false;
        }

        if (_implicitAllTagless)
        {
            --_remainingNodes;
            status = PbfStatus.init;
            return true;
        }

        auto start = _stream;
        size_t pairCount;
        bool waitingForValue;

        while (true)
        {
            ulong raw;
            bool hasValue;
            if (!_stream.next(raw, hasValue, status))
                return false;
            if (!hasValue)
            {
                status = PbfStatus.failure(
                    PbfError.denseTagNodeCountMismatch,
                    _stream.lastValueOffset,
                    10);
                return false;
            }

            if (raw == 0)
            {
                if (waitingForValue)
                {
                    status = PbfStatus.failure(
                        PbfError.denseTagMissingValue,
                        _stream.lastValueOffset,
                        10);
                    return false;
                }
                break;
            }

            static if (ValidateStringIds)
            {
                uint sid;
                if (!validateStringId(
                    raw,
                    _stream.lastValueOffset,
                    _table,
                    sid,
                    status))
                    return false;
            }

            if (!waitingForValue)
                waitingForValue = true;
            else
            {
                waitingForValue = false;
                ++pairCount;
            }
        }

        if (!DenseTagRange.fromValidated(start, _table, pairCount, tags, status))
            return false;

        --_remainingNodes;
        status = PbfStatus.init;
        return true;
    }

public:
    /**
     * Verify that exactly the validated node count consumed the tag stream.
     *
     * Params:
     *   status = Receives success or an unexpected trailing/missing segment.
     *
     * Returns:
     *   `true` when the cursor is exactly exhausted; `false` otherwise.
     */
    pragma(inline, true)
    bool finish(out PbfStatus status) @safe nothrow @nogc
    {
        if (_remainingNodes != 0)
        {
            status = PbfStatus.failure(PbfError.denseTagNodeCountMismatch, 0, 10);
            return false;
        }

        if (_implicitAllTagless)
        {
            status = PbfStatus.init;
            return true;
        }

        ulong raw;
        bool hasValue;
        if (!_stream.next(raw, hasValue, status))
            return false;
        if (hasValue)
        {
            status = PbfStatus.failure(
                PbfError.denseTagNodeCountMismatch,
                _stream.lastValueOffset,
                10);
            return false;
        }

        status = PbfStatus.init;
        return true;
    }
}

/**
 * Validate the complete DenseNodes `keys_vals` stream before node emission.
 *
 * Every non-zero value must be a positive signed-int32 StringTable ID, IDs
 * must resolve in `table`, key/value values must occur in pairs, and every
 * node in a non-empty stream must end in an explicit zero delimiter. When the
 * logical stream contains no values at all, all nodes are treated as tagless
 * as permitted by the OSMPBF schema.
 *
 * Params:
 *   group = Validated PrimitiveGroup containing zero or one merged DenseNodes.
 *   table = Indexed StringTable belonging to the same PrimitiveBlock.
 *   summary = Receives validated segment/value/tag counts.
 *   status = Receives success or the first semantic/wire failure.
 *
 * Returns:
 *   `true` when the tag stream is safe to expose; `false` otherwise.
 */
bool validateDenseTags(
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    out DenseTagValidationSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    summary = DenseTagValidationSummary.init;

    if (!group.hasDenseNodes || group.dense.keysValsCount == 0)
    {
        status = PbfStatus.init;
        return true;
    }

    auto stream = KeysValsCursor(group.raw);
    bool waitingForValue;

    while (true)
    {
        ulong raw;
        bool hasValue;
        if (!stream.next(raw, hasValue, status))
            return false;
        if (!hasValue)
            break;

        ++summary.encodedValueCount;

        if (raw == 0)
        {
            if (waitingForValue)
            {
                status = PbfStatus.failure(
                    PbfError.denseTagMissingValue,
                    stream.lastValueOffset,
                    10);
                return false;
            }

            ++summary.nodeSegments;
            if (summary.nodeSegments > group.dense.nodeCount)
            {
                status = PbfStatus.failure(
                    PbfError.denseTagNodeCountMismatch,
                    stream.lastValueOffset,
                    10);
                return false;
            }
            continue;
        }

        uint sid;
        if (!validateStringId(raw, stream.lastValueOffset, table, sid, status))
            return false;

        if (!waitingForValue)
            waitingForValue = true;
        else
        {
            waitingForValue = false;
            ++summary.tagCount;
        }
    }

    if (waitingForValue)
    {
        status = PbfStatus.failure(PbfError.denseTagMissingValue, 0, 10);
        return false;
    }

    if (summary.encodedValueCount != group.dense.keysValsCount ||
        summary.nodeSegments != group.dense.nodeCount)
    {
        status = PbfStatus.failure(PbfError.denseTagNodeCountMismatch, 0, 10);
        return false;
    }

    status = PbfStatus.init;
    return true;
}

pragma(inline, true)
private bool validateStringId(
    ulong raw,
    size_t offset,
    StringTableView table,
    out uint sid,
    out PbfStatus status)
    @safe nothrow @nogc
{
    sid = 0;

    // `keys_vals` is int32, and index zero is reserved exclusively as the
    // per-node delimiter. Negative int32 encodings and values outside the
    // positive int32 domain cannot denote StringTable IDs.
    if (raw == 0 || raw > int.max)
    {
        status = PbfStatus.failure(PbfError.invalidDenseTagStringId, offset, 10);
        return false;
    }

    sid = cast(uint)raw;
    if (cast(size_t)sid >= table.length)
    {
        status = PbfStatus.failure(PbfError.denseTagStringIdOutOfRange, offset, 10);
        return false;
    }

    status = PbfStatus.init;
    return true;
}

pragma(inline, true)
private bool decodePrevalidatedPairScalars(
    scope ref KeysValsCursor stream,
    out DecodedDenseTagPair decoded,
    out PbfStatus status)
    @safe nothrow @nogc
{
    decoded = DecodedDenseTagPair.init;

    ulong rawKey;
    ulong rawValue;
    bool hasKey;
    bool hasValue;

    if (!stream.next(rawKey, hasKey, status) || !hasKey)
        return false;
    decoded.keyOffset = stream.lastValueOffset;

    if (!stream.next(rawValue, hasValue, status) || !hasValue)
        return false;
    decoded.valueOffset = stream.lastValueOffset;

    // The containing DenseTagRange exists only after full semantic preflight,
    // so both values are already proven valid positive int32 StringTable IDs.
    decoded.keySid = cast(uint)rawKey;
    decoded.valueSid = cast(uint)rawValue;
    status = PbfStatus.init;
    return true;
}


private struct KeysValsCursor
{
private:
    WireCursor _group;
    WireCursor _dense;
    WireCursor _packed;
    size_t _denseBase;
    size_t _packedBase;
    size_t _lastValueOffset;

public:
    this(const(ubyte)[] group) @safe nothrow @nogc
    {
        _group = WireCursor(group);
    }

    @property size_t lastValueOffset() const scope @safe pure nothrow @nogc
    {
        return _lastValueOffset;
    }

    pragma(inline, true)
    bool next(out ulong value, out bool hasValue, out PbfStatus status)
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
                if (!readVarint64(_packed, value, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = 10;
                    status = PbfStatus.fromDenseNodesWire(wire, _packedBase);
                    return false;
                }
                hasValue = true;
                status = PbfStatus.init;
                return true;
            }

            while (!_dense.empty)
            {
                FieldHeader field;
                WireStatus wire;
                if (!readFieldHeader(_dense, field, wire))
                {
                    status = PbfStatus.fromDenseNodesWire(wire, _denseBase);
                    return false;
                }

                if (field.number == 10 && field.wireType == WireType.varint)
                {
                    _lastValueOffset = _denseBase + _dense.offset;
                    if (!readVarint64(_dense, value, wire))
                    {
                        if (wire.fieldNumber == 0)
                            wire.fieldNumber = field.number;
                        status = PbfStatus.fromDenseNodesWire(wire, _denseBase);
                        return false;
                    }
                    hasValue = true;
                    status = PbfStatus.init;
                    return true;
                }

                if (field.number == 10 && field.wireType == WireType.lengthDelimited)
                {
                    bool ok;
                    auto packed = readLengthDelimitedCursor(
                        _dense,
                        field.number,
                        ok,
                        wire);
                    if (!ok)
                    {
                        status = PbfStatus.fromDenseNodesWire(wire, _denseBase);
                        return false;
                    }
                    _packedBase = _denseBase + _dense.offset - packed.remaining;
                    _packed = packed;
                    break;
                }

                if (!skipFieldValue(_dense, field, wire))
                {
                    status = PbfStatus.fromDenseNodesWire(wire, _denseBase);
                    return false;
                }
            }

            if (!_packed.empty || !_dense.empty)
                continue;

            while (!_group.empty)
            {
                FieldHeader field;
                WireStatus wire;
                if (!readFieldHeader(_group, field, wire))
                {
                    status = PbfStatus.fromPrimitiveGroupWire(wire);
                    return false;
                }

                if (field.number == 2 && field.wireType == WireType.lengthDelimited)
                {
                    bool ok;
                    auto dense = readLengthDelimitedCursor(
                        _group,
                        field.number,
                        ok,
                        wire);
                    if (!ok)
                    {
                        status = PbfStatus.fromPrimitiveGroupWire(wire);
                        return false;
                    }
                    _denseBase = _group.offset - dense.remaining;
                    _dense = dense;
                    break;
                }

                if (!skipFieldValue(_group, field, wire))
                {
                    status = PbfStatus.fromPrimitiveGroupWire(wire);
                    return false;
                }
            }

            if (!_dense.empty)
                continue;

            if (_group.empty)
            {
                status = PbfStatus.init;
                return true;
            }
        }
    }
}

unittest
{
    // Two nodes: first has one tag, second is explicitly tagless.
    const(ubyte)[] groupBytes = [
        0x12, 0x12,
        0x0a, 0x02, 0x02, 0x02,
        0x42, 0x02, 0x02, 0x02,
        0x4a, 0x02, 0x02, 0x02,
        0x52, 0x04, 0x01, 0x02, 0x00, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    const(ubyte)[] strings = [0, 'n', 'a', 'm', 'e', 'x'];
    import osm.io.pbf.string_table : StringRef;
    StringRef[3] refs = [StringRef(0, 0), StringRef(1, 4), StringRef(5, 1)];
    StringTableView table = StringTableView(strings, refs[]);

    DenseTagValidationSummary summary;
    assert(validateDenseTags(group, table, summary, status));
    assert(summary.nodeSegments == 2);
    assert(summary.tagCount == 1);
    assert(summary.encodedValueCount == 4);

    DenseTagNodeCursor cursor = DenseTagNodeCursor(group, table);
    DenseTagRange tags;
    assert(cursor.nextNode(tags, status));
    assert(tags.length == 1);
    TagView tag = tags.front;
    assert(tags.frontKeyStringId == 1 && tags.frontValueStringId == 2);
    const(ubyte)[] name = ['n', 'a', 'm', 'e'];
    const(ubyte)[] x = ['x'];
    assert(tag.key == name);
    assert(tag.value == x);
    tags.popFront();
    assert(tags.empty);

    assert(cursor.nextNode(tags, status));
    assert(tags.empty);
    assert(cursor.finish(status));
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    const(ubyte)[] strings = [0, 'k', 'v'];
    StringRef[3] refs = [StringRef(0, 0), StringRef(1, 1), StringRef(2, 1)];
    StringTableView table = StringTableView(strings, refs[]);
    PrimitiveGroupLayout group;
    DenseTagValidationSummary summary;
    PbfStatus status;

    // Completely empty keys_vals is the permitted all-tagless representation.
    const(ubyte)[] allTagless = [
        0x12, 0x0c,
        0x0a, 0x02, 0x02, 0x02,
        0x42, 0x02, 0x02, 0x02,
        0x4a, 0x02, 0x02, 0x02,
    ];
    assert(decodePrimitiveGroupLayout(allTagless, group, status));
    assert(validateDenseTags(group, table, summary, status));
    assert(summary.tagCount == 0 && summary.nodeSegments == 0);

    // Once keys_vals is non-empty, every node requires its delimiter.
    const(ubyte)[] missingNodeDelimiter = [
        0x12, 0x11,
        0x0a, 0x02, 0x02, 0x02,
        0x42, 0x02, 0x02, 0x02,
        0x4a, 0x02, 0x02, 0x02,
        0x52, 0x03, 0x01, 0x02, 0x00,
    ];
    assert(decodePrimitiveGroupLayout(missingNodeDelimiter, group, status));
    assert(!validateDenseTags(group, table, summary, status));
    assert(status.error == PbfError.denseTagNodeCountMismatch);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    const(ubyte)[] strings = [0, 'k', 'v'];
    StringRef[3] refs = [StringRef(0, 0), StringRef(1, 1), StringRef(2, 1)];
    StringTableView table = StringTableView(strings, refs[]);
    PrimitiveGroupLayout group;
    DenseTagValidationSummary summary;
    PbfStatus status;

    // Key without a value before the delimiter.
    const(ubyte)[] missingValue = [
        0x12, 0x0d,
        0x0a, 0x01, 0x02,
        0x42, 0x01, 0x02,
        0x4a, 0x01, 0x02,
        0x52, 0x02, 0x01, 0x00,
    ];
    assert(decodePrimitiveGroupLayout(missingValue, group, status));
    assert(!validateDenseTags(group, table, summary, status));
    assert(status.error == PbfError.denseTagMissingValue);

    // Positive int32 StringTable ID outside the current table.
    const(ubyte)[] outOfRange = [
        0x12, 0x0e,
        0x0a, 0x01, 0x02,
        0x42, 0x01, 0x02,
        0x4a, 0x01, 0x02,
        0x52, 0x03, 0x03, 0x02, 0x00,
    ];
    assert(decodePrimitiveGroupLayout(outOfRange, group, status));
    assert(!validateDenseTags(group, table, summary, status));
    assert(status.error == PbfError.denseTagStringIdOutOfRange);

    // 2^31 is outside the positive int32 domain used for dense StringTable IDs.
    const(ubyte)[] invalidInt32 = [
        0x12, 0x12,
        0x0a, 0x01, 0x02,
        0x42, 0x01, 0x02,
        0x4a, 0x01, 0x02,
        0x52, 0x07, 0x80, 0x80, 0x80, 0x80, 0x08, 0x02, 0x00,
    ];
    assert(decodePrimitiveGroupLayout(invalidInt32, group, status));
    assert(!validateDenseTags(group, table, summary, status));
    assert(status.error == PbfError.invalidDenseTagStringId);
}

unittest
{
    // Packable fields may mix unpacked occurrences with multiple packed
    // segments, and repeated DenseNodes messages merge logically.
    const(ubyte)[] groupBytes = [
        0x12, 0x0c,
        0x08, 0x02, 0x40, 0x02, 0x48, 0x02,
        0x50, 0x01, 0x52, 0x02, 0x02, 0x00,
        0x12, 0x08,
        0x08, 0x02, 0x40, 0x02, 0x48, 0x02,
        0x50, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    const(ubyte)[] strings = [0, 'k', 'v'];
    import osm.io.pbf.string_table : StringRef;
    StringRef[3] refs = [StringRef(0, 0), StringRef(1, 1), StringRef(2, 1)];
    StringTableView table = StringTableView(strings, refs[]);

    DenseTagValidationSummary summary;
    assert(validateDenseTags(group, table, summary, status));
    assert(summary.nodeSegments == 2);
    assert(summary.tagCount == 1);
}

version (unittest)
{
    pragma(msg, "LAYOUT source/osm/io/pbf/dense_tags.d: DenseTagRange.sizeof=", DenseTagRange.sizeof, " TagView.sizeof=", TagView.sizeof, " KeysValsCursor.sizeof=", KeysValsCursor.sizeof, " WireCursor.sizeof=", WireCursor.sizeof);
}
