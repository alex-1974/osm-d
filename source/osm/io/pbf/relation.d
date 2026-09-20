/**
 * Streaming decode of regular OSMPBF `Relation` messages.
 *
 * A Relation exposes its signed OSM ID, ordered tags, optional Info metadata,
 * and ordered members. Relation member IDs are reconstructed from the
 * delta-coded `memids` column. `roles_sid`, `memids`, and `types` are treated
 * as parallel logical arrays; packed, unpacked, repeated, and segmented
 * protobuf representations are accepted and concatenated in field order.
 *
 * Every Relation in the PrimitiveGroup is fully preflighted before the first
 * sink call. Member order and duplicates are preserved exactly. Member roles
 * are validated against the PrimitiveBlock StringTable; StringTable index zero
 * is valid and represents the empty role. Only the schema MemberType values
 * NODE, WAY, and RELATION are accepted by this validated decoder.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-19
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.relation;

import osm.view.element : ElementType, isElementView;
import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.info :
    InfoView,
    finalizeInfo,
    mergeInfoMessage;
import osm.io.pbf.primitive_block : PrimitiveBlockLayout;
import osm.io.pbf.primitive_group : PrimitiveGroupLayout;
import osm.io.pbf.string_table : StringTableView;
import osm.io.pbf.tags :
    TagRange,
    TagValidationSummary,
    buildTagRange,
    validateTags;
import osm.util.checked : checkedAdd;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;
import osm.wire.varint :
    readSVarint64,
    readVarint32,
    readVarint64;


/** Validated OSMPBF Relation member type. */
enum RelationMemberType : ubyte
{
    node = 0,
    way = 1,
    relation = 2,
}


/** One validated borrowed Relation member. */
struct RelationMemberView
{
    /// OSM element type of the referenced member.
    RelationMemberType type;
    /// Absolute signed OSM member ID reconstructed from `memids` deltas.
    long id;
    /// Validated StringTable ID of the role. Zero denotes the empty role.
    uint roleSid;
    /// Borrowed raw role bytes. Empty for role StringTable ID zero.
    const(ubyte)[] role;
}


/** Validation summary for one Relation's three parallel member columns. */
struct RelationMemberValidationSummary
{
    /// Logical `roles_sid` count.
    size_t roleCount;
    /// Logical `memids` count.
    size_t idCount;
    /// Logical `types` count.
    size_t typeCount;
    /// Final absolute member ID after checked delta accumulation.
    long finalId;

    /** Number of validated members. */
    @property size_t memberCount() const @safe pure nothrow @nogc
    {
        return idCount;
    }
}


/** Borrowed input range over one validated Relation's ordered members. */
struct RelationMemberRange
{
private:
    Int32FieldCursor _roles;
    SInt64FieldCursor _ids;
    Int32FieldCursor _types;
    StringTableView _table;
    long _currentId;
    RelationMemberView _front;
    size_t _remaining;

public:
    /** Returns `true` when no Relation member remains. */
    pragma(inline, true)
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _remaining == 0;
    }

    /** Returns the number of Relation members not yet consumed. */
    pragma(inline, true)
    @property size_t length() const @safe pure nothrow @nogc
    {
        return _remaining;
    }

    /** Return the current validated Relation member. */
    pragma(inline, true)
    @property RelationMemberView front() const @safe nothrow @nogc
    in (!empty)
    {
        return _front;
    }

    /** Advance to the next already validated Relation member. */
    pragma(inline, true)
    void popFront() @safe nothrow @nogc
    in (!empty)
    {
        --_remaining;
        if (_remaining == 0)
        {
            _front = RelationMemberView.init;
            return;
        }

        PbfStatus ignored;
        RelationMemberView next;
        if (!decodeValidatedMember(
            _roles,
            _ids,
            _types,
            _table,
            _currentId,
            next,
            ignored))
        {
            // Immutable bytes were completely preflighted before construction.
            _remaining = 0;
            _front = RelationMemberView.init;
            return;
        }

        _front = next;
    }
}


/** One validated regular Relation with exact borrowed provenance. */
struct RelationView
{
    /// Signed OSM object ID as encoded by the Relation `int64` field.
    long id;
    /// Borrowed ordered normal-element tags.
    TagRange tags;
    /// Borrowed ordered Relation members.
    RelationMemberRange members;
    /// Optional merged Info metadata.
    InfoView info;

    /// Complete original serialized Relation payload, excluding group key/length.
    const(ubyte)[] raw;
    /// Byte offset of `raw` within `PrimitiveGroupLayout.raw`.
    size_t rawOffset;

    /// Semantic OSM element kind.
    @property ElementType type() const scope
        @safe pure nothrow @nogc
    {
        return ElementType.relation;
    }
}

static assert(isElementView!RelationView);


/** Summary of one completed regular-Relation decode operation. */
struct RelationDecodeSummary
{
    /// Number of Relation messages delivered to the sink.
    size_t relationCount;
    /// Number of ordered tags exposed across all emitted Relations.
    size_t tagCount;
    /// Number of ordered members exposed across all emitted Relations.
    size_t memberCount;
}


private struct ParsedRelation
{
    long id;
    InfoView info;
    TagValidationSummary tags;
    RelationMemberValidationSummary members;
}


/**
 * Decode every regular Relation in one validated PrimitiveGroup.
 *
 * The complete group is semantically preflighted before the first sink call.
 * Required Relation IDs, merged Info metadata, normal-element tags, role
 * StringTable references, parallel member-column lengths, member types, and
 * checked member-ID deltas are therefore known valid before any observable
 * output occurs.
 *
 * This first implementation deliberately uses the same semantic parser again
 * during the emission pass rather than adding an unmeasured fast path. The
 * duplicated work establishes a simple correctness baseline for later
 * profiling.
 */
bool decodeRelations(Sink)(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    ref Sink sink,
    out RelationDecodeSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    summary = RelationDecodeSummary.init;

    if (group.relationOccurrences == 0)
    {
        status = PbfStatus.init;
        return true;
    }

    size_t preflightCount;
    size_t preflightTagCount;
    size_t preflightMemberCount;
    auto preflight = RelationMessageCursor(group.raw);

    while (true)
    {
        RelationMessageRef relationRef;
        bool hasRelation;
        if (!preflight.next(relationRef, hasRelation, status))
            return false;
        if (!hasRelation)
            break;

        ParsedRelation parsed;
        if (!parseRelation(block, relationRef, table, parsed, status))
            return false;

        ++preflightCount;
        preflightTagCount += parsed.tags.tagCount;
        preflightMemberCount += parsed.members.memberCount;
    }

    if (preflightCount != group.relationOccurrences)
    {
        status = PbfStatus.failure(
            PbfError.relationCountMismatch,
            0,
            4);
        return false;
    }

    auto relations = RelationMessageCursor(group.raw);

    while (true)
    {
        RelationMessageRef relationRef;
        bool hasRelation;
        if (!relations.next(relationRef, hasRelation, status))
            return false;
        if (!hasRelation)
            break;

        ParsedRelation parsed;
        if (!parseRelation(block, relationRef, table, parsed, status))
            return false;

        TagRange tags;
        if (!buildTagRange(
            relationRef.bytes,
            relationRef.rawOffset,
            table,
            parsed.tags,
            tags,
            status))
            return false;

        RelationMemberRange members;
        if (!buildRelationMemberRange(
            relationRef.bytes,
            relationRef.rawOffset,
            table,
            parsed.members,
            members,
            status))
            return false;

        RelationView relation = RelationView(
            parsed.id,
            tags,
            members,
            parsed.info,
            relationRef.bytes,
            relationRef.rawOffset);

        sink.put(relation);
        ++summary.relationCount;
        summary.tagCount += parsed.tags.tagCount;
        summary.memberCount += parsed.members.memberCount;
    }

    if (summary.relationCount != preflightCount ||
        summary.tagCount != preflightTagCount ||
        summary.memberCount != preflightMemberCount)
    {
        status = PbfStatus.failure(
            PbfError.relationCountMismatch,
            0,
            4);
        return false;
    }

    status = PbfStatus.init;
    return true;
}


private bool parseRelation(
    ref const PrimitiveBlockLayout block,
    RelationMessageRef relationRef,
    StringTableView table,
    out ParsedRelation parsed,
    out PbfStatus status)
    @safe nothrow @nogc
{
    parsed = ParsedRelation.init;
    auto cursor = WireCursor(relationRef.bytes);
    bool hasId;

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromRelationWire(wire, relationRef.rawOffset);
            return false;
        }

        if (field.number == 1 && field.wireType == WireType.varint)
        {
            ulong raw;
            if (!readVarint64(cursor, raw, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = field.number;
                status = PbfStatus.fromRelationWire(
                    wire,
                    relationRef.rawOffset);
                return false;
            }

            // Relation.id is protobuf int64, not sint64. Preserve the exact
            // two's-complement value represented by the wire varint.
            parsed.id = cast(long)raw;
            hasId = true;
            continue;
        }

        if (field.number == 4 &&
            field.wireType == WireType.lengthDelimited)
        {
            const(ubyte)[] infoBytes;
            if (!readLengthDelimited(
                cursor,
                field.number,
                infoBytes,
                wire))
            {
                status = PbfStatus.fromRelationWire(
                    wire,
                    relationRef.rawOffset);
                return false;
            }

            const infoOffset =
                relationRef.rawOffset + cursor.offset - infoBytes.length;
            if (!mergeInfoMessage(
                infoBytes,
                infoOffset,
                parsed.info,
                status))
                return false;

            continue;
        }

        if (!skipFieldValue(cursor, field, wire))
        {
            status = PbfStatus.fromRelationWire(wire, relationRef.rawOffset);
            return false;
        }
    }

    if (!hasId)
    {
        status = PbfStatus.failure(
            PbfError.missingRelationId,
            relationRef.rawOffset,
            1);
        return false;
    }

    if (!finalizeInfo(block, table, parsed.info, status))
        return false;

    if (!validateTags(
        relationRef.bytes,
        relationRef.rawOffset,
        table,
        parsed.tags,
        status))
        return false;

    if (!validateRelationMembers(
        relationRef.bytes,
        relationRef.rawOffset,
        table,
        parsed.members,
        status))
        return false;

    status = PbfStatus.init;
    return true;
}


/**
 * Validate the complete logical Relation member columns.
 *
 * `roles_sid`, `memids`, and `types` are independently concatenated according
 * to protobuf repeated-field semantics and then consumed in lockstep. Role
 * StringTable ID zero is valid and denotes the empty role. Member IDs are
 * checked while reconstructing absolute IDs from signed deltas.
 */
bool validateRelationMembers(
    const(ubyte)[] input,
    size_t baseOffset,
    StringTableView table,
    out RelationMemberValidationSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    summary = RelationMemberValidationSummary.init;

    auto roles = Int32FieldCursor(input, baseOffset, 8);
    auto ids = SInt64FieldCursor(input, baseOffset, 9);
    auto types = Int32FieldCursor(input, baseOffset, 10);

    long currentId;

    while (true)
    {
        int roleSidValue;
        long idDelta;
        int typeValue;
        bool hasRole;
        bool hasId;
        bool hasType;

        if (!roles.next(roleSidValue, hasRole, status) ||
            !ids.next(idDelta, hasId, status) ||
            !types.next(typeValue, hasType, status))
            return false;

        if (hasRole)
            ++summary.roleCount;
        if (hasId)
            ++summary.idCount;
        if (hasType)
            ++summary.typeCount;

        if (hasRole != hasId || hasRole != hasType)
        {
            uint fieldNumber;
            if (!hasRole)
                fieldNumber = 8;
            else if (!hasId)
                fieldNumber = 9;
            else
                fieldNumber = 10;

            status = PbfStatus.failure(
                PbfError.relationMemberColumnLengthMismatch,
                baseOffset,
                fieldNumber);
            return false;
        }

        if (!hasRole)
            break;

        if (roleSidValue < 0)
        {
            status = PbfStatus.failure(
                PbfError.invalidRelationRoleStringId,
                roles.lastValueOffset,
                8);
            return false;
        }

        const roleSid = cast(uint)roleSidValue;
        if (cast(size_t)roleSid >= table.length)
        {
            status = PbfStatus.failure(
                PbfError.relationRoleStringIdOutOfRange,
                roles.lastValueOffset,
                8);
            return false;
        }

        long nextId;
        if (!checkedAdd(currentId, idDelta, nextId))
        {
            status = PbfStatus.failure(
                PbfError.relationMemberIdOverflow,
                ids.lastValueOffset,
                9);
            return false;
        }

        if (typeValue < 0 || typeValue > 2)
        {
            status = PbfStatus.failure(
                PbfError.unsupportedRelationMemberType,
                types.lastValueOffset,
                10);
            return false;
        }

        currentId = nextId;
    }

    summary.finalId = currentId;
    status = PbfStatus.init;
    return true;
}


/**
 * Build a borrowed Relation member range from already validated bytes.
 *
 * `summary` must come from `validateRelationMembers` for the same unchanged
 * bytes and StringTable.
 */
bool buildRelationMemberRange(
    const(ubyte)[] input,
    size_t baseOffset,
    StringTableView table,
    RelationMemberValidationSummary summary,
    out RelationMemberRange range,
    out PbfStatus status)
    @safe nothrow @nogc
{
    range = RelationMemberRange.init;
    range._roles = Int32FieldCursor(input, baseOffset, 8);
    range._ids = SInt64FieldCursor(input, baseOffset, 9);
    range._types = Int32FieldCursor(input, baseOffset, 10);
    range._table = table;
    range._remaining = summary.memberCount;

    if (range._remaining == 0)
    {
        status = PbfStatus.init;
        return true;
    }

    if (!decodeValidatedMember(
        range._roles,
        range._ids,
        range._types,
        table,
        range._currentId,
        range._front,
        status))
    {
        range = RelationMemberRange.init;
        return false;
    }

    status = PbfStatus.init;
    return true;
}


pragma(inline, true)
private bool decodeValidatedMember(
    ref Int32FieldCursor roles,
    ref SInt64FieldCursor ids,
    ref Int32FieldCursor types,
    StringTableView table,
    ref long currentId,
    out RelationMemberView member,
    out PbfStatus status)
    @safe nothrow @nogc
{
    member = RelationMemberView.init;

    int roleSidValue;
    long idDelta;
    int typeValue;
    bool hasRole;
    bool hasId;
    bool hasType;

    if (!roles.next(roleSidValue, hasRole, status) ||
        !ids.next(idDelta, hasId, status) ||
        !types.next(typeValue, hasType, status))
        return false;

    if (!hasRole || !hasId || !hasType)
    {
        status = PbfStatus.failure(
            PbfError.relationMemberColumnLengthMismatch,
            0,
            !hasRole ? 8 : (!hasId ? 9 : 10));
        return false;
    }

    if (roleSidValue < 0)
    {
        status = PbfStatus.failure(
            PbfError.invalidRelationRoleStringId,
            roles.lastValueOffset,
            8);
        return false;
    }

    const roleSid = cast(uint)roleSidValue;
    const(ubyte)[] role;
    if (!table.get(cast(size_t)roleSid, role))
    {
        status = PbfStatus.failure(
            PbfError.relationRoleStringIdOutOfRange,
            roles.lastValueOffset,
            8);
        return false;
    }

    long nextId;
    if (!checkedAdd(currentId, idDelta, nextId))
    {
        status = PbfStatus.failure(
            PbfError.relationMemberIdOverflow,
            ids.lastValueOffset,
            9);
        return false;
    }

    if (typeValue < 0 || typeValue > 2)
    {
        status = PbfStatus.failure(
            PbfError.unsupportedRelationMemberType,
            types.lastValueOffset,
            10);
        return false;
    }

    currentId = nextId;
    member = RelationMemberView(
        cast(RelationMemberType)typeValue,
        nextId,
        roleSid,
        role);

    status = PbfStatus.init;
    return true;
}


private struct RelationMessageRef
{
    const(ubyte)[] bytes;
    size_t rawOffset;
}


private struct RelationMessageCursor
{
private:
    WireCursor _group;

public:
    this(const(ubyte)[] group) @safe nothrow @nogc
    {
        _group = WireCursor(group);
    }

    bool next(
        out RelationMessageRef relation,
        out bool hasRelation,
        out PbfStatus status)
        @safe nothrow @nogc
    {
        relation = RelationMessageRef.init;
        hasRelation = false;

        while (!_group.empty)
        {
            FieldHeader field;
            WireStatus wire;
            if (!readFieldHeader(_group, field, wire))
            {
                status = PbfStatus.fromPrimitiveGroupWire(wire);
                return false;
            }

            if (field.number == 4 &&
                field.wireType == WireType.lengthDelimited)
            {
                const(ubyte)[] payload;
                if (!readLengthDelimited(
                    _group,
                    field.number,
                    payload,
                    wire))
                {
                    status = PbfStatus.fromPrimitiveGroupWire(wire);
                    return false;
                }

                relation = RelationMessageRef(
                    payload,
                    _group.offset - payload.length);
                hasRelation = true;
                status = PbfStatus.init;
                return true;
            }

            if (!skipFieldValue(_group, field, wire))
            {
                status = PbfStatus.fromPrimitiveGroupWire(wire);
                return false;
            }
        }

        status = PbfStatus.init;
        return true;
    }
}


/** Logical cursor over one repeated protobuf int32/enum field. */
private struct Int32FieldCursor
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

    bool next(out int value, out bool hasValue, out PbfStatus status)
        @safe nothrow @nogc
    {
        value = 0;
        hasValue = false;

        while (true)
        {
            if (!_packed.empty)
            {
                _lastValueOffset = _packedBase + _packed.offset;

                uint raw;
                WireStatus wire;
                if (!readVarint32(_packed, raw, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = _fieldNumber;
                    status = PbfStatus.fromRelationWire(wire, _packedBase);
                    return false;
                }

                value = cast(int)raw;
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
                    status = PbfStatus.fromRelationWire(
                        wire,
                        _baseOffset);
                    return false;
                }

                if (field.number == _fieldNumber &&
                    field.wireType == WireType.varint)
                {
                    _lastValueOffset =
                        _baseOffset + _message.offset;

                    uint raw;
                    if (!readVarint32(_message, raw, wire))
                    {
                        if (wire.fieldNumber == 0)
                            wire.fieldNumber = field.number;
                        status = PbfStatus.fromRelationWire(
                            wire,
                            _baseOffset);
                        return false;
                    }

                    value = cast(int)raw;
                    hasValue = true;
                    status = PbfStatus.init;
                    return true;
                }

                if (field.number == _fieldNumber &&
                    field.wireType == WireType.lengthDelimited)
                {
                    const(ubyte)[] packed;
                    if (!readLengthDelimited(
                        _message,
                        field.number,
                        packed,
                        wire))
                    {
                        status = PbfStatus.fromRelationWire(
                            wire,
                            _baseOffset);
                        return false;
                    }

                    _packedBase =
                        _baseOffset + _message.offset - packed.length;
                    _packed = WireCursor(packed);

                    if (!_packed.empty)
                        break;

                    // Empty packed occurrences are legal.
                    continue;
                }

                if (!skipFieldValue(_message, field, wire))
                {
                    status = PbfStatus.fromRelationWire(
                        wire,
                        _baseOffset);
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


/** Logical cursor over one repeated protobuf sint64 field. */
private struct SInt64FieldCursor
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

    bool next(out long value, out bool hasValue, out PbfStatus status)
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
                if (!readSVarint64(_packed, value, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = _fieldNumber;
                    status = PbfStatus.fromRelationWire(wire, _packedBase);
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
                    status = PbfStatus.fromRelationWire(
                        wire,
                        _baseOffset);
                    return false;
                }

                if (field.number == _fieldNumber &&
                    field.wireType == WireType.varint)
                {
                    _lastValueOffset =
                        _baseOffset + _message.offset;

                    if (!readSVarint64(_message, value, wire))
                    {
                        if (wire.fieldNumber == 0)
                            wire.fieldNumber = field.number;
                        status = PbfStatus.fromRelationWire(
                            wire,
                            _baseOffset);
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
                    if (!readLengthDelimited(
                        _message,
                        field.number,
                        packed,
                        wire))
                    {
                        status = PbfStatus.fromRelationWire(
                            wire,
                            _baseOffset);
                        return false;
                    }

                    _packedBase =
                        _baseOffset + _message.offset - packed.length;
                    _packed = WireCursor(packed);

                    if (!_packed.empty)
                        break;

                    // Empty packed occurrences are legal.
                    continue;
                }

                if (!skipFieldValue(_message, field, wire))
                {
                    status = PbfStatus.fromRelationWire(
                        wire,
                        _baseOffset);
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
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Relation id=100, tag (1->2), Info(version=7), and three members:
    // NODE 10 role="", WAY 12 role="from", RELATION 11 role="to".
    const(ubyte)[] groupBytes = [
        0x22, 0x1b,
        0x08, 0x64,
        0x12, 0x01, 0x01,
        0x1a, 0x01, 0x02,
        0x22, 0x02, 0x08, 0x07,
        0x42, 0x03, 0x00, 0x03, 0x04,
        0x4a, 0x03, 0x14, 0x04, 0x01,
        0x52, 0x03, 0x00, 0x01, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));
    assert(group.relationOccurrences == 1);

    PrimitiveBlockLayout block;

    const(ubyte)[] strings = [
        0,
        'k',
        'v',
        'f', 'r', 'o', 'm',
        't', 'o'
    ];
    StringRef[5] refs = [
        StringRef(0, 0),
        StringRef(1, 1),
        StringRef(2, 1),
        StringRef(3, 4),
        StringRef(7, 2),
    ];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        RelationView relation;
        size_t used;

        void put(RelationView value) @safe nothrow @nogc
        {
            relation = value;
            ++used;
        }
    }

    Sink sink;
    RelationDecodeSummary summary;
    assert(decodeRelations(
        block,
        group,
        table,
        sink,
        summary,
        status));

    assert(status.ok);
    assert(summary.relationCount == 1);
    assert(summary.tagCount == 1);
    assert(summary.memberCount == 3);
    assert(sink.used == 1);
    assert(sink.relation.id == 100);
    assert(sink.relation.info.hasVersion);
    assert(sink.relation.info.version_ == 7);

    auto tags = sink.relation.tags;
    assert(tags.length == 1);
    assert(tags.front.keySid == 1);
    assert(tags.front.valueSid == 2);

    auto members = sink.relation.members;
    assert(members.length == 3);

    assert(members.front.type == RelationMemberType.node);
    assert(members.front.id == 10);
    assert(members.front.roleSid == 0);
    assert(members.front.role.length == 0);
    members.popFront();

    assert(members.front.type == RelationMemberType.way);
    assert(members.front.id == 12);
    assert(members.front.roleSid == 3);
    const(ubyte)[] from = ['f', 'r', 'o', 'm'];
    assert(members.front.role == from);
    members.popFront();

    assert(members.front.type == RelationMemberType.relation);
    assert(members.front.id == 11);
    assert(members.front.roleSid == 4);
    const(ubyte)[] to = ['t', 'o'];
    assert(members.front.role == to);
    members.popFront();

    assert(members.empty);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Duplicate id uses protobuf last-one-wins.
    // Member columns are split between unpacked and packed occurrences.
    // All three members deliberately reference NODE 5 and must be preserved.
    const(ubyte)[] groupBytes = [
        0x22, 0x16,
        0x08, 0x01,
        0x08, 0x07,
        0x40, 0x00,
        0x42, 0x02, 0x01, 0x01,
        0x48, 0x0a,
        0x4a, 0x02, 0x00, 0x00,
        0x50, 0x00,
        0x52, 0x02, 0x00, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;

    const(ubyte)[] strings = [0, 'r'];
    StringRef[2] refs = [
        StringRef(0, 0),
        StringRef(1, 1),
    ];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        RelationView relation;
        void put(RelationView value) @safe nothrow @nogc
        {
            relation = value;
        }
    }

    Sink sink;
    RelationDecodeSummary summary;
    assert(decodeRelations(
        block,
        group,
        table,
        sink,
        summary,
        status));

    assert(sink.relation.id == 7);
    assert(summary.memberCount == 3);

    auto members = sink.relation.members;
    foreach (_; 0 .. 3)
    {
        assert(!members.empty);
        assert(members.front.type == RelationMemberType.node);
        assert(members.front.id == 5);
        members.popFront();
    }
    assert(members.empty);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // One role and member ID but no matching type.
    const(ubyte)[] groupBytes = [
        0x22, 0x06,
        0x08, 0x01,
        0x40, 0x00,
        0x48, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        size_t used;
        void put(RelationView) @safe nothrow @nogc
        {
            ++used;
        }
    }

    Sink sink;
    RelationDecodeSummary summary;
    assert(!decodeRelations(
        block,
        group,
        table,
        sink,
        summary,
        status));
    assert(status.error == PbfError.relationMemberColumnLengthMismatch);
    assert(status.fieldNumber == 10);
    assert(sink.used == 0);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Role StringTable ID 5 is outside the one-entry table.
    const(ubyte)[] groupBytes = [
        0x22, 0x08,
        0x08, 0x01,
        0x40, 0x05,
        0x48, 0x02,
        0x50, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        void put(RelationView) @safe nothrow @nogc {}
    }

    Sink sink;
    RelationDecodeSummary summary;
    assert(!decodeRelations(
        block,
        group,
        table,
        sink,
        summary,
        status));
    assert(status.error == PbfError.relationRoleStringIdOutOfRange);
    assert(status.fieldNumber == 8);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // roles_sid is schema int32. A wire value whose low 32 bits are -1 is not
    // a valid StringTable index.
    const(ubyte)[] groupBytes = [
        0x22, 0x11,
        0x08, 0x01,
        0x40,
        0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
        0x48, 0x02,
        0x50, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        void put(RelationView) @safe nothrow @nogc {}
    }

    Sink sink;
    RelationDecodeSummary summary;
    assert(!decodeRelations(
        block,
        group,
        table,
        sink,
        summary,
        status));
    assert(status.error == PbfError.invalidRelationRoleStringId);
    assert(status.fieldNumber == 8);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // MemberType 3 is not defined by the OSMPBF Relation schema.
    const(ubyte)[] groupBytes = [
        0x22, 0x08,
        0x08, 0x01,
        0x40, 0x00,
        0x48, 0x02,
        0x50, 0x03,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        void put(RelationView) @safe nothrow @nogc {}
    }

    Sink sink;
    RelationDecodeSummary summary;
    assert(!decodeRelations(
        block,
        group,
        table,
        sink,
        summary,
        status));
    assert(status.error == PbfError.unsupportedRelationMemberType);
    assert(status.fieldNumber == 10);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // The first Relation is valid. The second accumulates long.max then +1,
    // which must fail group preflight before the first sink call.
    const(ubyte)[] groupBytes = [
        0x22, 0x02,
        0x08, 0x01,

        0x22, 0x17,
        0x08, 0x02,
        0x42, 0x02, 0x00, 0x00,
        0x4a, 0x0b,
        0xfe, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
        0x02,
        0x52, 0x02, 0x00, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));
    assert(group.relationOccurrences == 2);

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        size_t used;
        void put(RelationView) @safe nothrow @nogc
        {
            ++used;
        }
    }

    Sink sink;
    RelationDecodeSummary summary;
    assert(!decodeRelations(
        block,
        group,
        table,
        sink,
        summary,
        status));
    assert(status.error == PbfError.relationMemberIdOverflow);
    assert(status.fieldNumber == 9);
    assert(sink.used == 0);
    assert(summary.relationCount == 0);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    const(ubyte)[] groupBytes = [0x22, 0x00];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        size_t used;
        void put(RelationView) @safe nothrow @nogc
        {
            ++used;
        }
    }

    Sink sink;
    RelationDecodeSummary summary;
    assert(!decodeRelations(
        block,
        group,
        table,
        sink,
        summary,
        status));
    assert(status.error == PbfError.missingRelationId);
    assert(status.fieldNumber == 1);
    assert(sink.used == 0);
}


// RELATION_ADDITIONAL_INTEGRITY_TESTS
unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Relation.id is int64 and may carry an exact negative two's-complement
    // value. memids is sint64, so 0x01 reconstructs member ID -1.
    const(ubyte)[] groupBytes = [
        0x22, 0x11,
        0x08,
        0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
        0x40, 0x00,
        0x48, 0x01,
        0x50, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        RelationView relation;

        void put(RelationView value) @safe nothrow @nogc
        {
            relation = value;
        }
    }

    Sink sink;
    RelationDecodeSummary summary;
    assert(decodeRelations(
        block,
        group,
        table,
        sink,
        summary,
        status));

    assert(status.ok);
    assert(sink.relation.id == -1);
    assert(summary.memberCount == 1);

    auto members = sink.relation.members;
    assert(members.front.id == -1);
    assert(members.front.type == RelationMemberType.relation);
    assert(members.front.roleSid == 0);
    members.popFront();
    assert(members.empty);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // memids/types contain one value, roles_sid contains none.
    const(ubyte)[] groupBytes = [
        0x22, 0x06,
        0x08, 0x01,
        0x48, 0x02,
        0x50, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        size_t used;

        void put(RelationView) @safe nothrow @nogc
        {
            ++used;
        }
    }

    Sink sink;
    RelationDecodeSummary summary;
    assert(!decodeRelations(
        block,
        group,
        table,
        sink,
        summary,
        status));

    assert(status.error == PbfError.relationMemberColumnLengthMismatch);
    assert(status.fieldNumber == 8);
    assert(sink.used == 0);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // roles_sid/types contain one value, memids contains none.
    const(ubyte)[] groupBytes = [
        0x22, 0x06,
        0x08, 0x01,
        0x40, 0x00,
        0x50, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        size_t used;

        void put(RelationView) @safe nothrow @nogc
        {
            ++used;
        }
    }

    Sink sink;
    RelationDecodeSummary summary;
    assert(!decodeRelations(
        block,
        group,
        table,
        sink,
        summary,
        status));

    assert(status.error == PbfError.relationMemberColumnLengthMismatch);
    assert(status.fieldNumber == 9);
    assert(sink.used == 0);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;
    import osm.wire.error : WireError;

    // Packed memids contains a truncated varint. It must surface as a
    // Relation-specific wire error and remain invisible to the sink.
    const(ubyte)[] groupBytes = [
        0x22, 0x09,
        0x08, 0x01,
        0x40, 0x00,
        0x4a, 0x01, 0x80,
        0x50, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        size_t used;

        void put(RelationView) @safe nothrow @nogc
        {
            ++used;
        }
    }

    Sink sink;
    RelationDecodeSummary summary;
    assert(!decodeRelations(
        block,
        group,
        table,
        sink,
        summary,
        status));

    assert(status.error == PbfError.invalidRelationWire);
    assert(status.fieldNumber == 9);
    assert(status.wireError == WireError.truncatedVarint);
    assert(sink.used == 0);
}
