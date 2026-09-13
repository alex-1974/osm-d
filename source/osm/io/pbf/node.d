/**
 * Streaming decode of regular OSMPBF `Node` messages.
 *
 * Regular Node id/lat/lon fields are direct sint64 values, not delta coded.
 * Every Node in the PrimitiveGroup is fully preflighted before the first sink
 * call. Tags use the shared normal-element parallel-array decoder and Info
 * submessages are merged according to protobuf singular-message semantics.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-13
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.node;

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
import osm.util.checked : checkedMulAdd;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;
import osm.wire.varint : readSVarint64;

/** One validated regular Node with exact borrowed provenance. */
struct NodeView
{
    /// Signed OSM object ID.
    long id;
    /// Exact latitude in nanodegrees after granularity/offset conversion.
    long latNano;
    /// Exact longitude in nanodegrees after granularity/offset conversion.
    long lonNano;
    /// Borrowed ordered normal-element tags.
    TagRange tags;
    /// Optional merged Info metadata.
    InfoView info;

    /// Complete original serialized Node payload, excluding group key/length.
    const(ubyte)[] raw;
    /// Byte offset of `raw` within `PrimitiveGroupLayout.raw`.
    size_t rawOffset;
}

/** Summary of one completed regular-Node decode operation. */
struct NodeDecodeSummary
{
    /// Number of Node messages delivered to the sink.
    size_t nodeCount;
    /// Number of ordered tags exposed across all emitted nodes.
    size_t tagCount;
}

private struct ParsedNode
{
    long id;
    long latNano;
    long lonNano;
    InfoView info;
    TagValidationSummary tags;
}

/**
 * Decode every regular Node in one validated PrimitiveGroup.
 *
 * The complete group is semantically preflighted before the first sink call.
 * Required id/lat/lon presence, exact coordinate conversion, merged Info,
 * StringTable references, and key/value parallel-array lengths are therefore
 * all known valid before any observable output occurs.
 */
bool decodeNodes(Sink)(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    ref Sink sink,
    out NodeDecodeSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    summary = NodeDecodeSummary.init;

    if (group.nodeOccurrences == 0)
    {
        status = PbfStatus.init;
        return true;
    }

    size_t preflightCount;
    size_t preflightTagCount;
    auto preflight = NodeMessageCursor(group.raw);

    while (true)
    {
        NodeMessageRef nodeRef;
        bool hasNode;
        if (!preflight.next(nodeRef, hasNode, status))
            return false;
        if (!hasNode)
            break;

        ParsedNode parsed;
        if (!parseNode(block, nodeRef, table, parsed, status))
            return false;

        ++preflightCount;
        preflightTagCount += parsed.tags.tagCount;
    }

    if (preflightCount != group.nodeOccurrences)
    {
        status = PbfStatus.failure(PbfError.nodeCountMismatch, 0, 1);
        return false;
    }

    auto nodes = NodeMessageCursor(group.raw);

    while (true)
    {
        NodeMessageRef nodeRef;
        bool hasNode;
        if (!nodes.next(nodeRef, hasNode, status))
            return false;
        if (!hasNode)
            break;

        ParsedNode parsed;
        if (!parseNode(block, nodeRef, table, parsed, status))
            return false;

        TagRange tags;
        if (!buildTagRange(
            nodeRef.bytes,
            nodeRef.rawOffset,
            table,
            parsed.tags,
            tags,
            status))
            return false;

        NodeView node = NodeView(
            parsed.id,
            parsed.latNano,
            parsed.lonNano,
            tags,
            parsed.info,
            nodeRef.bytes,
            nodeRef.rawOffset);

        sink.put(node);
        ++summary.nodeCount;
        summary.tagCount += parsed.tags.tagCount;
    }

    if (summary.nodeCount != preflightCount ||
        summary.tagCount != preflightTagCount)
    {
        status = PbfStatus.failure(PbfError.nodeCountMismatch, 0, 1);
        return false;
    }

    status = PbfStatus.init;
    return true;
}

private bool parseNode(
    ref const PrimitiveBlockLayout block,
    NodeMessageRef nodeRef,
    StringTableView table,
    out ParsedNode parsed,
    out PbfStatus status)
    @safe nothrow @nogc
{
    parsed = ParsedNode.init;
    auto cursor = WireCursor(nodeRef.bytes);

    bool hasId;
    bool hasLat;
    bool hasLon;
    long latValue;
    long lonValue;

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromNodeWire(wire, nodeRef.rawOffset);
            return false;
        }

        if ((field.number == 1 || field.number == 8 || field.number == 9) &&
            field.wireType == WireType.varint)
        {
            long value;
            if (!readSVarint64(cursor, value, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = field.number;
                status = PbfStatus.fromNodeWire(wire, nodeRef.rawOffset);
                return false;
            }

            switch (field.number)
            {
                case 1:
                    parsed.id = value;
                    hasId = true;
                    break;

                case 8:
                    latValue = value;
                    hasLat = true;
                    break;

                case 9:
                    lonValue = value;
                    hasLon = true;
                    break;

                default:
                    assert(0, "unexpected Node scalar field");
            }
            continue;
        }

        if (field.number == 4 && field.wireType == WireType.lengthDelimited)
        {
            const(ubyte)[] infoBytes;
            if (!readLengthDelimited(cursor, field.number, infoBytes, wire))
            {
                status = PbfStatus.fromNodeWire(wire, nodeRef.rawOffset);
                return false;
            }

            const infoOffset =
                nodeRef.rawOffset + cursor.offset - infoBytes.length;
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
            status = PbfStatus.fromNodeWire(wire, nodeRef.rawOffset);
            return false;
        }
    }

    if (!hasId)
    {
        status = PbfStatus.failure(
            PbfError.missingNodeId,
            nodeRef.rawOffset,
            1);
        return false;
    }
    if (!hasLat)
    {
        status = PbfStatus.failure(
            PbfError.missingNodeLat,
            nodeRef.rawOffset,
            8);
        return false;
    }
    if (!hasLon)
    {
        status = PbfStatus.failure(
            PbfError.missingNodeLon,
            nodeRef.rawOffset,
            9);
        return false;
    }

    if (!checkedMulAdd(
        block.latOffset,
        cast(long)block.granularity,
        latValue,
        parsed.latNano))
    {
        status = PbfStatus.failure(
            PbfError.nodeCoordinateOverflow,
            nodeRef.rawOffset,
            8);
        return false;
    }

    if (!checkedMulAdd(
        block.lonOffset,
        cast(long)block.granularity,
        lonValue,
        parsed.lonNano))
    {
        status = PbfStatus.failure(
            PbfError.nodeCoordinateOverflow,
            nodeRef.rawOffset,
            9);
        return false;
    }

    if (!finalizeInfo(block, table, parsed.info, status))
        return false;

    if (!validateTags(
        nodeRef.bytes,
        nodeRef.rawOffset,
        table,
        parsed.tags,
        status))
        return false;

    status = PbfStatus.init;
    return true;
}

private struct NodeMessageRef
{
    const(ubyte)[] bytes;
    size_t rawOffset;
}

/** Allocation-free cursor over repeated regular Node fields in a group. */
private struct NodeMessageCursor
{
private:
    WireCursor _group;

public:
    this(const(ubyte)[] group) @safe nothrow @nogc
    {
        _group = WireCursor(group);
    }

    bool next(
        out NodeMessageRef node,
        out bool hasNode,
        out PbfStatus status)
        @safe nothrow @nogc
    {
        node = NodeMessageRef.init;
        hasNode = false;

        while (!_group.empty)
        {
            FieldHeader field;
            WireStatus wire;
            if (!readFieldHeader(_group, field, wire))
            {
                status = PbfStatus.fromPrimitiveGroupWire(wire);
                return false;
            }

            if (field.number == 1 && field.wireType == WireType.lengthDelimited)
            {
                const(ubyte)[] payload;
                if (!readLengthDelimited(_group, field.number, payload, wire))
                {
                    status = PbfStatus.fromPrimitiveGroupWire(wire);
                    return false;
                }

                node = NodeMessageRef(
                    payload,
                    _group.offset - payload.length);
                hasNode = true;
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

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // One Node:
    // id=100, tags (1->2, 3->4), Info(version=7,timestamp=10,user=5,visible),
    // lat=10, lon=-20.
    const(ubyte)[] groupBytes = [
        0x0a, 0x19,
        0x08, 0xc8, 0x01,
        0x12, 0x02, 0x01, 0x03,
        0x1a, 0x02, 0x02, 0x04,
        0x22, 0x08,
        0x08, 0x07,
        0x10, 0x0a,
        0x28, 0x05,
        0x30, 0x01,
        0x40, 0x14,
        0x48, 0x27,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));
    assert(group.nodeOccurrences == 1);

    PrimitiveBlockLayout block;
    block.granularity = 100;
    block.dateGranularity = 1000;
    block.latOffset = 1000;
    block.lonOffset = -1000;

    const(ubyte)[] strings = [0, 'k', 'v', 'n', 'x', 'u'];
    StringRef[6] refs = [
        StringRef(0, 0),
        StringRef(1, 1),
        StringRef(2, 1),
        StringRef(3, 1),
        StringRef(4, 1),
        StringRef(5, 1),
    ];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        NodeView node;
        size_t used;

        void put(NodeView value) @safe nothrow @nogc
        {
            node = value;
            ++used;
        }
    }

    Sink sink;
    NodeDecodeSummary summary;
    assert(decodeNodes(block, group, table, sink, summary, status));
    assert(status.ok);
    assert(summary.nodeCount == 1 && summary.tagCount == 2);
    assert(sink.used == 1);

    assert(sink.node.id == 100);
    assert(sink.node.latNano == 2000);
    assert(sink.node.lonNano == -3000);
    assert(sink.node.raw.length == 25);

    auto tags = sink.node.tags;
    assert(tags.length == 2);
    assert(tags.front.keySid == 1 && tags.front.valueSid == 2);
    tags.popFront();
    assert(tags.front.keySid == 3 && tags.front.valueSid == 4);

    assert(sink.node.info.hasVersion && sink.node.info.version_ == 7);
    assert(sink.node.info.hasTimestamp);
    assert(sink.node.info.timestampMillis == 10_000);
    assert(sink.node.info.hasUser && sink.node.info.userSid == 5);
    const(ubyte)[] u = ['u'];
    assert(sink.node.info.user == u);
    assert(sink.node.info.hasVisible && sink.node.info.visible);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // First Node is valid. Second Node omits required lon.
    // Full preflight must reject the group before the sink sees the first Node.
    const(ubyte)[] groupBytes = [
        0x0a, 0x06,
        0x08, 0x02,
        0x40, 0x02,
        0x48, 0x02,

        0x0a, 0x04,
        0x08, 0x04,
        0x40, 0x04,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));
    assert(group.nodeOccurrences == 2);

    PrimitiveBlockLayout block;
    block.granularity = 100;

    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    struct CountingSink
    {
        size_t used;
        void put(NodeView) @safe nothrow @nogc { ++used; }
    }

    CountingSink sink;
    NodeDecodeSummary summary;
    assert(!decodeNodes(block, group, table, sink, summary, status));
    assert(status.error == PbfError.missingNodeLon);
    assert(status.fieldNumber == 9);
    assert(sink.used == 0);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Direct coordinate conversion overflow is also caught during preflight.
    const(ubyte)[] groupBytes = [
        0x0a, 0x06,
        0x08, 0x02,
        0x40, 0x02,
        0x48, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    block.granularity = 2;
    block.latOffset = long.max;

    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    struct CountingSink
    {
        size_t used;
        void put(NodeView) @safe nothrow @nogc { ++used; }
    }

    CountingSink sink;
    NodeDecodeSummary summary;
    assert(!decodeNodes(block, group, table, sink, summary, status));
    assert(status.error == PbfError.nodeCoordinateOverflow);
    assert(status.fieldNumber == 8);
    assert(sink.used == 0);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Duplicate singular Node scalars use protobuf last-one-wins semantics.
    // Repeated embedded Info occurrences merge; a superseded invalid user_sid
    // must not invalidate the final merged Info value.
    const(ubyte)[] groupBytes = [
        0x0a, 0x18,
        0x08, 0x02,                   // id = 1
        0x08, 0x04,                   // id = 2 (wins)
        0x22, 0x04, 0x08, 0x01, 0x28, 0x63, // Info: version=1, user_sid=99
        0x22, 0x04, 0x08, 0x02, 0x28, 0x01, // Info: version=2, user_sid=1 (wins)
        0x40, 0x02,                   // lat = 1
        0x40, 0x01,                   // lat = -1 (wins)
        0x48, 0x04,                   // lon = 2
        0x48, 0x03,                   // lon = -2 (wins)
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    block.granularity = 100;

    const(ubyte)[] strings = [0, 'u'];
    StringRef[2] refs = [StringRef(0, 0), StringRef(1, 1)];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        NodeView node;
        size_t used;
        void put(NodeView value) @safe nothrow @nogc
        {
            node = value;
            ++used;
        }
    }

    Sink sink;
    NodeDecodeSummary summary;
    assert(decodeNodes(block, group, table, sink, summary, status));
    assert(status.ok && sink.used == 1);
    assert(sink.node.id == 2);
    assert(sink.node.latNano == -100);
    assert(sink.node.lonNano == -200);
    assert(sink.node.info.hasVersion && sink.node.info.version_ == 2);
    assert(sink.node.info.hasUser && sink.node.info.userSid == 1);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // A semantic tag failure in the second Node must be discovered during
    // preflight, before the first valid Node reaches the sink.
    const(ubyte)[] groupBytes = [
        0x0a, 0x06,
        0x08, 0x02,
        0x40, 0x00,
        0x48, 0x00,

        0x0a, 0x0c,
        0x08, 0x04,
        0x12, 0x01, 0x01,
        0x1a, 0x01, 0x03,
        0x40, 0x00,
        0x48, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;

    const(ubyte)[] strings = [0, 'k', 'v'];
    StringRef[3] refs = [
        StringRef(0, 0),
        StringRef(1, 1),
        StringRef(2, 1),
    ];
    StringTableView table = StringTableView(strings, refs[]);

    struct CountingSink
    {
        size_t used;
        void put(NodeView) @safe nothrow @nogc { ++used; }
    }

    CountingSink sink;
    NodeDecodeSummary summary;
    assert(!decodeNodes(block, group, table, sink, summary, status));
    assert(status.error == PbfError.tagStringIdOutOfRange);
    assert(status.fieldNumber == 3);
    assert(sink.used == 0);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Likewise, invalid Info in a later Node cannot leak an earlier prefix.
    const(ubyte)[] groupBytes = [
        0x0a, 0x06,
        0x08, 0x02,
        0x40, 0x00,
        0x48, 0x00,

        0x0a, 0x0a,
        0x08, 0x04,
        0x22, 0x02, 0x28, 0x03,
        0x40, 0x00,
        0x48, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;

    const(ubyte)[] strings = [0, 'u'];
    StringRef[2] refs = [StringRef(0, 0), StringRef(1, 1)];
    StringTableView table = StringTableView(strings, refs[]);

    struct CountingSink
    {
        size_t used;
        void put(NodeView) @safe nothrow @nogc { ++used; }
    }

    CountingSink sink;
    NodeDecodeSummary summary;
    assert(!decodeNodes(block, group, table, sink, summary, status));
    assert(status.error == PbfError.infoUserStringIdOutOfRange);
    assert(status.fieldNumber == 5);
    assert(sink.used == 0);
}
