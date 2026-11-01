/**
 * Allocation-free semantic decoding of OSMPBF `DenseInfo` metadata.
 *
 * DenseInfo stores metadata column-wise. Version and visibility are direct
 * repeated values; timestamp, changeset, uid, and user string-table ID are
 * delta coded. Each column is optional as a whole. When present, this module
 * requires exactly one value per DenseNode so positional association can never
 * become ambiguous. Packed and legal unpacked protobuf forms are both accepted.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.dense_info;

import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.primitive_block : PrimitiveBlockLayout;
import osm.io.pbf.primitive_group : PrimitiveGroupLayout;
import osm.io.pbf.string_table : StringTableView;
import osm.util.checked : checkedAdd, checkedMulAdd;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;
import osm.wire.varint : readSVarint32, readSVarint64, readVarint64;

/** One dense node's decoded optional metadata. */
struct DenseInfoView
{
    /// Whether the version column is present for the DenseNodes sequence.
    bool hasVersion;
    /// Raw OSM object version from the DenseInfo int32 column.
    int version_;

    /// Whether the timestamp column is present.
    bool hasTimestamp;
    /// Cumulative PBF timestamp value before `date_granularity` scaling.
    long timestampValue;
    /// Exact timestamp in milliseconds since the Unix epoch.
    long timestampMillis;

    /// Whether the changeset column is present.
    bool hasChangeset;
    /// Cumulative changeset identifier.
    long changeset;

    /// Whether the uid column is present.
    bool hasUid;
    /// Cumulative signed uid value represented by DenseInfo.
    int uid;

    /// Whether the user_sid column is present.
    bool hasUser;
    /// Validated cumulative StringTable ID for the username.
    uint userSid;
    /// Borrowed username bytes from the PrimitiveBlock StringTable.
    const(ubyte)[] user;

    /// Whether the visible column is present.
    bool hasVisible;
    /// Decoded protobuf boolean when `hasVisible` is true.
    bool visible;
}

/** Validated shape of the optional DenseInfo columns. */
package(osm)
struct DenseInfoValidationSummary
{
    /// Number of values in the optional version column.
    size_t versionCount;
    /// Number of values in the optional timestamp column.
    size_t timestampCount;
    /// Number of values in the optional changeset column.
    size_t changesetCount;
    /// Number of values in the optional uid column.
    size_t uidCount;
    /// Number of values in the optional user_sid column.
    size_t userSidCount;
    /// Number of values in the optional visible column.
    size_t visibleCount;

    /** Returns `true` when the version column is present. */
    @property bool hasVersion() const @safe pure nothrow @nogc
    {
        return versionCount != 0;
    }

    /** Returns `true` when the timestamp column is present. */
    @property bool hasTimestamp() const @safe pure nothrow @nogc
    {
        return timestampCount != 0;
    }

    /** Returns `true` when the changeset column is present. */
    @property bool hasChangeset() const @safe pure nothrow @nogc
    {
        return changesetCount != 0;
    }

    /** Returns `true` when the uid column is present. */
    @property bool hasUid() const @safe pure nothrow @nogc
    {
        return uidCount != 0;
    }

    /** Returns `true` when the user_sid column is present. */
    @property bool hasUser() const @safe pure nothrow @nogc
    {
        return userSidCount != 0;
    }

    /** Returns `true` when the visible column is present. */
    @property bool hasVisible() const @safe pure nothrow @nogc
    {
        return visibleCount != 0;
    }
}

private struct DenseInfoPreflightState
{
    DenseInfoValidationSummary summary;
    long timestamp;
    long changeset;
    long uid;
    long userSid;
}

/**
 * Validate all DenseInfo columns before any DenseNode is emitted.
 *
 * DenseInfo itself is optional, and each metadata column may independently be
 * absent. A present column must contain exactly `group.dense.nodeCount` values.
 * Delta-coded columns are fully accumulated with overflow checks. Every
 * cumulative user_sid is validated against `table`, and timestamp scaling by
 * `block.dateGranularity` is checked for exact signed-64-bit representability.
 *
 * Params:
 *   block = PrimitiveBlock layout providing timestamp granularity.
 *   group = Validated PrimitiveGroup containing the merged DenseNodes message.
 *   table = Indexed StringTable belonging to the same PrimitiveBlock.
 *   summary = Receives validated per-column counts.
 *   status = Receives success or a structured DenseInfo failure.
 *
 * Returns:
 *   `true` when every present DenseInfo column is safe to decode; `false`
 *   otherwise.
 */
package(osm)
bool validateDenseInfo(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    out DenseInfoValidationSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    summary = DenseInfoValidationSummary.init;

    if (!group.hasDenseNodes || !group.dense.hasDenseInfo)
    {
        status = PbfStatus.init;
        return true;
    }

    DenseInfoPreflightState state;
    auto groupCursor = WireCursor(group.raw);

    while (!groupCursor.empty)
    {
        FieldHeader groupField;
        WireStatus wire;
        if (!readFieldHeader(groupCursor, groupField, wire))
        {
            status = PbfStatus.fromPrimitiveGroupWire(wire);
            return false;
        }

        if (groupField.number == 2 && groupField.wireType == WireType.lengthDelimited)
        {
            const(ubyte)[] dense;
            if (!readLengthDelimited(groupCursor, groupField.number, dense, wire))
            {
                status = PbfStatus.fromPrimitiveGroupWire(wire);
                return false;
            }

            const denseBase = groupCursor.offset - dense.length;
            if (!scanDenseInfoInDenseNodes(
                dense,
                denseBase,
                block,
                table,
                state,
                status))
                return false;
            continue;
        }

        if (!skipFieldValue(groupCursor, groupField, wire))
        {
            status = PbfStatus.fromPrimitiveGroupWire(wire);
            return false;
        }
    }

    const nodeCount = group.dense.nodeCount;
    if (!validateColumnLength(state.summary.versionCount, nodeCount, 1, status) ||
        !validateColumnLength(state.summary.timestampCount, nodeCount, 2, status) ||
        !validateColumnLength(state.summary.changesetCount, nodeCount, 3, status) ||
        !validateColumnLength(state.summary.uidCount, nodeCount, 4, status) ||
        !validateColumnLength(state.summary.userSidCount, nodeCount, 5, status) ||
        !validateColumnLength(state.summary.visibleCount, nodeCount, 6, status))
        return false;

    summary = state.summary;
    status = PbfStatus.init;
    return true;
}

private bool scanDenseInfoInDenseNodes(
    const(ubyte)[] dense,
    size_t denseBase,
    ref const PrimitiveBlockLayout block,
    StringTableView table,
    ref DenseInfoPreflightState state,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto cursor = WireCursor(dense);

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromDenseNodesWire(wire, denseBase);
            return false;
        }

        if (field.number == 5 && field.wireType == WireType.lengthDelimited)
        {
            const(ubyte)[] info;
            if (!readLengthDelimited(cursor, field.number, info, wire))
            {
                status = PbfStatus.fromDenseNodesWire(wire, denseBase);
                return false;
            }

            const infoBase = denseBase + cursor.offset - info.length;
            if (!scanDenseInfoMessage(
                info,
                infoBase,
                block,
                table,
                state,
                status))
                return false;
            continue;
        }

        if (!skipFieldValue(cursor, field, wire))
        {
            status = PbfStatus.fromDenseNodesWire(wire, denseBase);
            return false;
        }
    }

    status = PbfStatus.init;
    return true;
}

private bool scanDenseInfoMessage(
    const(ubyte)[] info,
    size_t infoBase,
    ref const PrimitiveBlockLayout block,
    StringTableView table,
    ref DenseInfoPreflightState state,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto cursor = WireCursor(info);

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromDenseInfoWire(wire, infoBase);
            return false;
        }

        if (field.number >= 1 && field.number <= 6)
        {
            if (field.wireType == WireType.varint)
            {
                const valueOffset = infoBase + cursor.offset;
                long value;
                if (!readDenseInfoValue(cursor, field.number, value, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = field.number;
                    status = PbfStatus.fromDenseInfoWire(wire, infoBase);
                    return false;
                }
                if (!acceptDenseInfoValue(
                    field.number,
                    value,
                    valueOffset,
                    block,
                    table,
                    state,
                    status))
                    return false;
                continue;
            }

            if (field.wireType == WireType.lengthDelimited)
            {
                const(ubyte)[] packed;
                if (!readLengthDelimited(cursor, field.number, packed, wire))
                {
                    status = PbfStatus.fromDenseInfoWire(wire, infoBase);
                    return false;
                }

                auto packedCursor = WireCursor(packed);
                const packedBase = infoBase + cursor.offset - packed.length;
                while (!packedCursor.empty)
                {
                    const valueOffset = packedBase + packedCursor.offset;
                    long value;
                    if (!readDenseInfoValue(packedCursor, field.number, value, wire))
                    {
                        if (wire.fieldNumber == 0)
                            wire.fieldNumber = field.number;
                        status = PbfStatus.fromDenseInfoWire(wire, packedBase);
                        return false;
                    }
                    if (!acceptDenseInfoValue(
                        field.number,
                        value,
                        valueOffset,
                        block,
                        table,
                        state,
                        status))
                        return false;
                }
                continue;
            }
        }

        if (!skipFieldValue(cursor, field, wire))
        {
            status = PbfStatus.fromDenseInfoWire(wire, infoBase);
            return false;
        }
    }

    status = PbfStatus.init;
    return true;
}

private bool readDenseInfoValue(
    ref WireCursor cursor,
    uint fieldNumber,
    out long value,
    out WireStatus wire)
    @safe nothrow @nogc
{
    value = 0;

    switch (fieldNumber)
    {
        case 1:
        {
            ulong raw;
            if (!readVarint64(cursor, raw, wire))
                return false;
            // Protobuf int32 parsing keeps the low 32 bits of the varint.
            value = cast(int)raw;
            return true;
        }

        case 2:
        case 3:
            return readSVarint64(cursor, value, wire);

        case 4:
        case 5:
            int narrow;
            if (!readSVarint32(cursor, narrow, wire))
                return false;
            value = narrow;
            return true;

        case 6:
        {
            ulong raw;
            if (!readVarint64(cursor, raw, wire))
                return false;
            value = raw == 0 ? 0 : 1;
            return true;
        }

        default:
            wire = WireStatus.init;
            return false;
    }
}

private bool acceptDenseInfoValue(
    uint fieldNumber,
    long value,
    size_t offset,
    ref const PrimitiveBlockLayout block,
    StringTableView table,
    ref DenseInfoPreflightState state,
    out PbfStatus status)
    @safe nothrow @nogc
{
    long next;

    switch (fieldNumber)
    {
        case 1:
            ++state.summary.versionCount;
            break;

        case 2:
            if (!checkedAdd(state.timestamp, value, next))
            {
                status = PbfStatus.failure(
                    PbfError.denseInfoDeltaOverflow, offset, fieldNumber);
                return false;
            }
            state.timestamp = next;

            long millis;
            if (!checkedMulAdd(0, cast(long)block.dateGranularity, next, millis))
            {
                status = PbfStatus.failure(
                    PbfError.denseInfoTimestampOverflow, offset, fieldNumber);
                return false;
            }
            ++state.summary.timestampCount;
            break;

        case 3:
            if (!checkedAdd(state.changeset, value, next))
            {
                status = PbfStatus.failure(
                    PbfError.denseInfoDeltaOverflow, offset, fieldNumber);
                return false;
            }
            state.changeset = next;
            ++state.summary.changesetCount;
            break;

        case 4:
            if (!checkedAdd(state.uid, value, next))
            {
                status = PbfStatus.failure(
                    PbfError.denseInfoDeltaOverflow, offset, fieldNumber);
                return false;
            }
            if (next < int.min || next > int.max)
            {
                status = PbfStatus.failure(
                    PbfError.denseInfoUidOutOfRange, offset, fieldNumber);
                return false;
            }
            state.uid = next;
            ++state.summary.uidCount;
            break;

        case 5:
            if (!checkedAdd(state.userSid, value, next))
            {
                status = PbfStatus.failure(
                    PbfError.denseInfoDeltaOverflow, offset, fieldNumber);
                return false;
            }
            if (next < 0 || cast(ulong)next >= cast(ulong)table.length)
            {
                status = PbfStatus.failure(
                    PbfError.denseInfoUserStringIdOutOfRange,
                    offset,
                    fieldNumber);
                return false;
            }
            state.userSid = next;
            ++state.summary.userSidCount;
            break;

        case 6:
            ++state.summary.visibleCount;
            break;

        default:
            assert(0, "unexpected DenseInfo field");
    }

    status = PbfStatus.init;
    return true;
}

private bool validateColumnLength(
    size_t count,
    size_t nodeCount,
    uint fieldNumber,
    out PbfStatus status)
    @safe pure nothrow @nogc
{
    if (count != 0 && count != nodeCount)
    {
        status = PbfStatus.failure(
            PbfError.denseInfoColumnLengthMismatch,
            0,
            fieldNumber);
        return false;
    }

    status = PbfStatus.init;
    return true;
}

/**
 * Sequential cursor producing DenseInfo metadata for each dense node.
 *
 * Construct this only after `validateDenseInfo` succeeds for the same block,
 * group, and StringTable.
 *
 * The public `nextNode` path remains defensive and repeats semantic arithmetic
 * and range checks. Production DenseNodes emission may use the package-internal
 * prevalidated path only while the validated block/group/StringTable backing is
 * unchanged.
 */
package(osm)
struct DenseInfoNodeCursor
{
private:
    DenseInfoColumnCursor _versions;
    DenseInfoColumnCursor _timestamps;
    DenseInfoColumnCursor _changesets;
    DenseInfoColumnCursor _uids;
    DenseInfoColumnCursor _userSids;
    DenseInfoColumnCursor _visibles;
    DenseInfoValidationSummary _summary;
    StringTableView _table;
    long _dateGranularity;
    long _timestamp;
    long _changeset;
    long _uid;
    long _userSid;
    size_t _remainingNodes;

public:
    /** Initialize a cursor over prevalidated DenseInfo columns. */
    this(
        ref const PrimitiveBlockLayout block,
        ref const PrimitiveGroupLayout group,
        StringTableView table,
        DenseInfoValidationSummary summary)
        @safe nothrow @nogc
    {
        _versions = DenseInfoColumnCursor(group.raw, 1);
        _timestamps = DenseInfoColumnCursor(group.raw, 2);
        _changesets = DenseInfoColumnCursor(group.raw, 3);
        _uids = DenseInfoColumnCursor(group.raw, 4);
        _userSids = DenseInfoColumnCursor(group.raw, 5);
        _visibles = DenseInfoColumnCursor(group.raw, 6);
        _summary = summary;
        _table = table;
        _dateGranularity = block.dateGranularity;
        _remainingNodes = group.dense.nodeCount;
    }

    /** Decode metadata for the next dense node defensively. */
    pragma(inline, true)
    bool nextNode(out DenseInfoView info, out PbfStatus status)
        @safe nothrow @nogc
    {
        return nextNodeImpl!true(info, status);
    }

package:
    /**
     * Decode the next node after complete DenseInfo semantic preflight.
     *
     * Preconditions:
     * - `validateDenseInfo` succeeded for the same block, PrimitiveGroup, and
     *   StringTable used to construct this cursor;
     * - their backing bytes and StringTable index remain unchanged.
     *
     * Wire decoding, column presence/cardinality observation, cursor failures,
     * and StringTable materialization remain checked. Only semantic arithmetic
     * and ID-domain checks already proved by preflight are omitted.
     */
    pragma(inline, true)
    bool nextPrevalidatedNode(out DenseInfoView info, out PbfStatus status)
        @safe nothrow @nogc
    {
        return nextNodeImpl!false(info, status);
    }

private:
    pragma(inline, true)
    bool nextNodeImpl(bool ValidateSemanticChecks)(
        out DenseInfoView info,
        out PbfStatus status)
        @safe nothrow @nogc
    {
        info = DenseInfoView.init;

        if (_remainingNodes == 0)
        {
            status = PbfStatus.failure(
                PbfError.denseInfoColumnLengthMismatch,
                0,
                5);
            return false;
        }

        long value;
        bool hasValue;

        if (_summary.hasVersion)
        {
            if (!_versions.next(value, hasValue, status))
                return false;
            if (!hasValue)
                return missingValue(1, status);
            info.hasVersion = true;
            info.version_ = cast(int)value;
        }

        if (_summary.hasTimestamp)
        {
            if (!_timestamps.next(value, hasValue, status))
                return false;
            if (!hasValue)
                return missingValue(2, status);

            long next;
            static if (ValidateSemanticChecks)
            {
                if (!checkedAdd(_timestamp, value, next))
                    return deltaOverflow(2, status);
            }
            else
                next = _timestamp + value;

            _timestamp = next;

            long millis;
            static if (ValidateSemanticChecks)
            {
                if (!checkedMulAdd(0, _dateGranularity, next, millis))
                {
                    status = PbfStatus.failure(
                        PbfError.denseInfoTimestampOverflow,
                        0,
                        2);
                    return false;
                }
            }
            else
                millis = _dateGranularity * next;

            info.hasTimestamp = true;
            info.timestampValue = next;
            info.timestampMillis = millis;
        }

        if (_summary.hasChangeset)
        {
            if (!_changesets.next(value, hasValue, status))
                return false;
            if (!hasValue)
                return missingValue(3, status);

            long next;
            static if (ValidateSemanticChecks)
            {
                if (!checkedAdd(_changeset, value, next))
                    return deltaOverflow(3, status);
            }
            else
                next = _changeset + value;

            _changeset = next;
            info.hasChangeset = true;
            info.changeset = next;
        }

        if (_summary.hasUid)
        {
            if (!_uids.next(value, hasValue, status))
                return false;
            if (!hasValue)
                return missingValue(4, status);

            long next;
            static if (ValidateSemanticChecks)
            {
                if (!checkedAdd(_uid, value, next))
                    return deltaOverflow(4, status);

                if (next < int.min || next > int.max)
                {
                    status = PbfStatus.failure(
                        PbfError.denseInfoUidOutOfRange,
                        0,
                        4);
                    return false;
                }
            }
            else
                next = _uid + value;

            _uid = next;
            info.hasUid = true;
            info.uid = cast(int)next;
        }

        if (_summary.hasUser)
        {
            if (!_userSids.next(value, hasValue, status))
                return false;
            if (!hasValue)
                return missingValue(5, status);

            long next;
            static if (ValidateSemanticChecks)
            {
                if (!checkedAdd(_userSid, value, next))
                    return deltaOverflow(5, status);

                if (next < 0 || cast(ulong)next >= cast(ulong)_table.length)
                {
                    status = PbfStatus.failure(
                        PbfError.denseInfoUserStringIdOutOfRange,
                        0,
                        5);
                    return false;
                }
            }
            else
                next = _userSid + value;

            // Materialization remains defensive even on the prevalidated path.
            const(ubyte)[] user;
            if (!_table.get(cast(size_t)next, user))
            {
                status = PbfStatus.failure(
                    PbfError.denseInfoUserStringIdOutOfRange,
                    0,
                    5);
                return false;
            }

            _userSid = next;
            info.hasUser = true;
            info.userSid = cast(uint)next;
            info.user = user;
        }

        if (_summary.hasVisible)
        {
            if (!_visibles.next(value, hasValue, status))
                return false;
            if (!hasValue)
                return missingValue(6, status);
            info.hasVisible = true;
            info.visible = value != 0;
        }

        --_remainingNodes;
        status = PbfStatus.init;
        return true;
    }

public:
    /** Verify that all prevalidated columns were consumed exactly. */
    bool finish(out PbfStatus status) @safe nothrow @nogc
    {
        if (_remainingNodes != 0)
        {
            status = PbfStatus.failure(
                PbfError.denseInfoColumnLengthMismatch,
                0,
                5);
            return false;
        }

        if (_summary.hasVersion && !finishColumn(_versions, 1, status))
            return false;
        if (_summary.hasTimestamp && !finishColumn(_timestamps, 2, status))
            return false;
        if (_summary.hasChangeset && !finishColumn(_changesets, 3, status))
            return false;
        if (_summary.hasUid && !finishColumn(_uids, 4, status))
            return false;
        if (_summary.hasUser && !finishColumn(_userSids, 5, status))
            return false;
        if (_summary.hasVisible && !finishColumn(_visibles, 6, status))
            return false;

        status = PbfStatus.init;
        return true;
    }

private:
    static bool finishColumn(
        ref DenseInfoColumnCursor cursor,
        uint fieldNumber,
        out PbfStatus status)
        @safe nothrow @nogc
    {
        long ignored;
        bool hasExtra;
        if (!cursor.next(ignored, hasExtra, status))
            return false;
        if (hasExtra)
        {
            status = PbfStatus.failure(
                PbfError.denseInfoColumnLengthMismatch,
                0,
                fieldNumber);
            return false;
        }
        status = PbfStatus.init;
        return true;
    }

    static bool missingValue(uint fieldNumber, out PbfStatus status)
        @safe pure nothrow @nogc
    {
        status = PbfStatus.failure(
            PbfError.denseInfoColumnLengthMismatch,
            0,
            fieldNumber);
        return false;
    }

    static bool deltaOverflow(uint fieldNumber, out PbfStatus status)
        @safe pure nothrow @nogc
    {
        status = PbfStatus.failure(PbfError.denseInfoDeltaOverflow, 0, fieldNumber);
        return false;
    }
}

private struct DenseInfoColumnCursor
{
private:
    WireCursor _group;
    WireCursor _dense;
    WireCursor _info;
    WireCursor _packed;
    size_t _denseBase;
    size_t _infoBase;
    size_t _packedBase;
    uint _fieldNumber;

public:
    this(const(ubyte)[] group, uint fieldNumber) @safe nothrow @nogc
    {
        _group = WireCursor(group);
        _fieldNumber = fieldNumber;
    }

    bool next(out long value, out bool hasValue, out PbfStatus status)
        @safe nothrow @nogc
    {
        value = 0;
        hasValue = false;

        while (true)
        {
            if (!_packed.empty)
            {
                WireStatus wire;
                if (!readDenseInfoValue(_packed, _fieldNumber, value, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = _fieldNumber;
                    status = PbfStatus.fromDenseInfoWire(wire, _packedBase);
                    return false;
                }
                hasValue = true;
                status = PbfStatus.init;
                return true;
            }

            while (!_info.empty)
            {
                FieldHeader field;
                WireStatus wire;
                if (!readFieldHeader(_info, field, wire))
                {
                    status = PbfStatus.fromDenseInfoWire(wire, _infoBase);
                    return false;
                }

                if (field.number == _fieldNumber && field.wireType == WireType.varint)
                {
                    if (!readDenseInfoValue(_info, _fieldNumber, value, wire))
                    {
                        if (wire.fieldNumber == 0)
                            wire.fieldNumber = field.number;
                        status = PbfStatus.fromDenseInfoWire(wire, _infoBase);
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
                    if (!readLengthDelimited(_info, field.number, packed, wire))
                    {
                        status = PbfStatus.fromDenseInfoWire(wire, _infoBase);
                        return false;
                    }
                    _packedBase = _infoBase + _info.offset - packed.length;
                    _packed = WireCursor(packed);
                    break;
                }

                if (!skipFieldValue(_info, field, wire))
                {
                    status = PbfStatus.fromDenseInfoWire(wire, _infoBase);
                    return false;
                }
            }

            if (!_packed.empty || !_info.empty)
                continue;

            while (!_dense.empty)
            {
                FieldHeader field;
                WireStatus wire;
                if (!readFieldHeader(_dense, field, wire))
                {
                    status = PbfStatus.fromDenseNodesWire(wire, _denseBase);
                    return false;
                }

                if (field.number == 5 && field.wireType == WireType.lengthDelimited)
                {
                    const(ubyte)[] info;
                    if (!readLengthDelimited(_dense, field.number, info, wire))
                    {
                        status = PbfStatus.fromDenseNodesWire(wire, _denseBase);
                        return false;
                    }
                    _infoBase = _denseBase + _dense.offset - info.length;
                    _info = WireCursor(info);
                    break;
                }

                if (!skipFieldValue(_dense, field, wire))
                {
                    status = PbfStatus.fromDenseNodesWire(wire, _denseBase);
                    return false;
                }
            }

            if (!_info.empty || !_dense.empty)
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
                    const(ubyte)[] dense;
                    if (!readLengthDelimited(_group, field.number, dense, wire))
                    {
                        status = PbfStatus.fromPrimitiveGroupWire(wire);
                        return false;
                    }
                    _denseBase = _group.offset - dense.length;
                    _dense = WireCursor(dense);
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
    // Three nodes, all six DenseInfo columns packed. Delta columns decode to:
    // timestamp 10,12,11; changeset 100,105,105; uid 7,8,6;
    // user_sid 1,2,1. Visible is true,false,true.
    const(ubyte)[] groupBytes = [
        0x12, 0x30,
        0x0a, 0x03, 0x02, 0x02, 0x02,
        0x2a, 0x1f,
        0x0a, 0x03, 0x01, 0x02, 0x03,
        0x12, 0x03, 0x14, 0x04, 0x01,
        0x1a, 0x04, 0xc8, 0x01, 0x0a, 0x00,
        0x22, 0x03, 0x0e, 0x02, 0x03,
        0x2a, 0x03, 0x02, 0x02, 0x01,
        0x32, 0x03, 0x01, 0x00, 0x01,
        0x42, 0x03, 0x02, 0x02, 0x02,
        0x4a, 0x03, 0x02, 0x02, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    block.dateGranularity = 1000;

    import osm.io.pbf.string_table : StringRef;
    const(ubyte)[] strings = [0, 'a', 'b'];
    StringRef[3] refs = [StringRef(0, 0), StringRef(1, 1), StringRef(2, 1)];
    StringTableView table = StringTableView(strings, refs[]);

    DenseInfoValidationSummary summary;
    assert(validateDenseInfo(block, group, table, summary, status));
    assert(summary.versionCount == 3);
    assert(summary.timestampCount == 3);
    assert(summary.changesetCount == 3);
    assert(summary.uidCount == 3);
    assert(summary.userSidCount == 3);
    assert(summary.visibleCount == 3);

    DenseInfoNodeCursor cursor = DenseInfoNodeCursor(block, group, table, summary);
    DenseInfoView info;
    assert(cursor.nextNode(info, status));
    assert(info.hasVersion && info.version_ == 1);
    assert(info.hasTimestamp && info.timestampValue == 10 && info.timestampMillis == 10_000);
    assert(info.hasChangeset && info.changeset == 100);
    assert(info.hasUid && info.uid == 7);
    assert(info.hasUser && info.userSid == 1);
    const(ubyte)[] a = ['a'];
    assert(info.user == a);
    assert(info.hasVisible && info.visible);

    assert(cursor.nextNode(info, status));
    assert(info.version_ == 2);
    assert(info.timestampValue == 12 && info.changeset == 105 && info.uid == 8);
    assert(info.userSid == 2 && !info.visible);

    assert(cursor.nextNode(info, status));
    assert(info.version_ == 3);
    assert(info.timestampValue == 11 && info.changeset == 105 && info.uid == 6);
    assert(info.userSid == 1 && info.visible);
    assert(cursor.finish(status));
}

unittest
{
    // Each metadata column is independently optional; unpacked form is legal.
    const(ubyte)[] groupBytes = [
        0x12, 0x16,
        0x08, 0x02, 0x08, 0x02,
        0x2a, 0x08,
        0x08, 0x05, 0x08, 0x06,
        0x30, 0x01, 0x30, 0x00,
        0x40, 0x02, 0x40, 0x02,
        0x48, 0x02, 0x48, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    import osm.io.pbf.string_table : StringRef;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    DenseInfoValidationSummary summary;
    assert(validateDenseInfo(block, group, table, summary, status));
    assert(summary.versionCount == 2);
    assert(summary.visibleCount == 2);
    assert(summary.timestampCount == 0);

    DenseInfoNodeCursor cursor = DenseInfoNodeCursor(block, group, table, summary);
    DenseInfoView info;
    assert(cursor.nextNode(info, status));
    assert(info.hasVersion && info.version_ == 5);
    assert(!info.hasTimestamp && !info.hasChangeset && !info.hasUid && !info.hasUser);
    assert(info.hasVisible && info.visible);
    assert(cursor.nextNode(info, status));
    assert(info.version_ == 6 && !info.visible);
    assert(cursor.finish(status));
}

unittest
{
    // A present column shorter than the DenseNodes sequence is ambiguous and rejected.
    const(ubyte)[] groupBytes = [
        0x12, 0x11,
        0x0a, 0x02, 0x02, 0x02,
        0x2a, 0x03, 0x0a, 0x01, 0x01,
        0x42, 0x02, 0x02, 0x02,
        0x4a, 0x02, 0x02, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    import osm.io.pbf.string_table : StringRef;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    DenseInfoValidationSummary summary;
    assert(!validateDenseInfo(block, group, table, summary, status));
    assert(status.error == PbfError.denseInfoColumnLengthMismatch);
    assert(status.fieldNumber == 1);
}

unittest
{
    // user_sid is delta coded and every cumulative index must be in range.
    const(ubyte)[] groupBytes = [
        0x12, 0x0e,
        0x0a, 0x01, 0x02,
        0x2a, 0x03, 0x2a, 0x01, 0x04,
        0x42, 0x01, 0x02,
        0x4a, 0x01, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    import osm.io.pbf.string_table : StringRef;
    const(ubyte)[] strings = [0, 'x'];
    StringRef[2] refs = [StringRef(0, 0), StringRef(1, 1)];
    StringTableView table = StringTableView(strings, refs[]);

    DenseInfoValidationSummary summary;
    assert(!validateDenseInfo(block, group, table, summary, status));
    assert(status.error == PbfError.denseInfoUserStringIdOutOfRange);
    assert(status.fieldNumber == 5);
}

unittest
{
    // Repeated DenseNodes/DenseInfo message occurrences merge in wire order.
    const(ubyte)[] groupBytes = [
        0x12, 0x11,
        0x0a, 0x01, 0x02,
        0x2a, 0x06, 0x0a, 0x01, 0x01, 0x2a, 0x01, 0x02,
        0x42, 0x01, 0x02,
        0x4a, 0x01, 0x02,
        0x12, 0x11,
        0x0a, 0x01, 0x02,
        0x2a, 0x06, 0x0a, 0x01, 0x02, 0x2a, 0x01, 0x00,
        0x42, 0x01, 0x02,
        0x4a, 0x01, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));
    assert(group.dense.occurrences == 2 && group.dense.nodeCount == 2);

    PrimitiveBlockLayout block;
    import osm.io.pbf.string_table : StringRef;
    const(ubyte)[] strings = [0, 'u'];
    StringRef[2] refs = [StringRef(0, 0), StringRef(1, 1)];
    StringTableView table = StringTableView(strings, refs[]);

    DenseInfoValidationSummary summary;
    assert(validateDenseInfo(block, group, table, summary, status));
    DenseInfoNodeCursor cursor = DenseInfoNodeCursor(block, group, table, summary);
    DenseInfoView info;
    assert(cursor.nextNode(info, status));
    assert(info.version_ == 1 && info.userSid == 1);
    assert(cursor.nextNode(info, status));
    assert(info.version_ == 2 && info.userSid == 1);
    assert(cursor.finish(status));
}

unittest
{
    // Canonical ten-byte protobuf int32 encoding preserves version -1.
    const(ubyte)[] groupBytes = [
        0x12, 0x17,
        0x0a, 0x01, 0x02,
        0x2a, 0x0c,
        0x0a, 0x0a,
        0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
        0x42, 0x01, 0x02,
        0x4a, 0x01, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    import osm.io.pbf.string_table : StringRef;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    DenseInfoValidationSummary summary;
    assert(validateDenseInfo(block, group, table, summary, status));
    DenseInfoNodeCursor cursor = DenseInfoNodeCursor(block, group, table, summary);
    DenseInfoView info;
    assert(cursor.nextNode(info, status));
    assert(info.hasVersion && info.version_ == -1);
}

unittest
{
    // Timestamp scaling is checked during preflight, before node emission.
    const(ubyte)[] groupBytes = [
        0x12, 0x17,
        0x0a, 0x01, 0x02,
        0x2a, 0x0c,
        0x12, 0x0a,
        0xfe, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
        0x42, 0x01, 0x02,
        0x4a, 0x01, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    block.dateGranularity = 2;
    import osm.io.pbf.string_table : StringRef;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    DenseInfoValidationSummary summary;
    assert(!validateDenseInfo(block, group, table, summary, status));
    assert(status.error == PbfError.denseInfoTimestampOverflow);
    assert(status.fieldNumber == 2);
}
