/**
 * Streaming decode of validated OSMPBF DenseNodes coordinates and tags.
 *
 * Dense node IDs, latitudes and longitudes are delta-coded sint64 streams.
 * This module consumes a previously validated `PrimitiveGroupLayout`, performs
 * exact checked nanodegree coordinate conversion, validates the complete
 * dense tag stream, and emits borrowed-value node views through a statically
 * dispatched sink. DenseInfo remains outside this semantic slice.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.dense_nodes;

import osm.io.pbf.dense_tags :
    DenseTagNodeCursor,
    DenseTagRange,
    DenseTagValidationSummary,
    validateDenseTags;
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
import osm.wire.varint : readSVarint64;

/** One validated dense node with exact coordinates in nanodegrees. */
struct DenseNodeView
{
    /// Signed OSM object ID after delta accumulation.
    long id;
    /// Exact latitude in nanodegrees after granularity/offset conversion.
    long latNano;
    /// Exact longitude in nanodegrees after granularity/offset conversion.
    long lonNano;
    /// Borrowed ordered tags for this node.
    DenseTagRange tags;
}

/** Summary of one completed DenseNodes decode operation. */
struct DenseNodeDecodeSummary
{
    /// Number of nodes delivered to the sink.
    size_t nodeCount;
    /// Number of ordered tags exposed across all emitted nodes.
    size_t tagCount;
}

/**
 * Decode validated DenseNodes coordinates and tags into a static sink.
 *
 * `group` must have been produced by `decodePrimitiveGroupLayout`, and
 * `table` must be the StringTable view built from the same PrimitiveBlock.
 * Before the first sink call, coordinate conversion and the complete dense
 * tag stream are preflighted, so malformed tag structure, invalid string IDs,
 * or coordinate overflow cannot be discovered only after a node prefix was
 * already emitted.
 *
 * The sink must provide `void put(DenseNodeView)` and itself satisfy the
 * `@safe nothrow @nogc` contract required by this function instantiation.
 *
 * Params:
 *   block = Validated PrimitiveBlock layout providing granularity and offsets.
 *   group = Validated PrimitiveGroup layout containing DenseNodes data.
 *   table = Indexed StringTable belonging to `block`.
 *   sink = Consumer receiving nodes in merged protobuf column order.
 *   summary = Receives the number of emitted nodes.
 *   status = Receives success or a checked arithmetic/defensive wire failure.
 *
 * Returns:
 *   `true` on complete decode; `false` otherwise.
 */
bool decodeDenseNodes(Sink)(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    ref Sink sink,
    out DenseNodeDecodeSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    summary = DenseNodeDecodeSummary.init;

    if (!group.hasDenseNodes)
    {
        status = PbfStatus.init;
        return true;
    }

    if (group.dense.idCount != group.dense.latCount ||
        group.dense.idCount != group.dense.lonCount)
    {
        status = PbfStatus.failure(PbfError.denseNodeColumnLengthMismatch, 0, 2);
        return false;
    }

    if (!preflightCoordinates(block, group, status))
        return false;

    DenseTagValidationSummary tagValidation;
    if (!validateDenseTags(group, table, tagValidation, status))
        return false;

    DenseTagNodeCursor tagNodes = DenseTagNodeCursor(group, table);
    DenseColumnCursor ids = DenseColumnCursor(group.raw, 1);
    DenseColumnCursor lats = DenseColumnCursor(group.raw, 8);
    DenseColumnCursor lons = DenseColumnCursor(group.raw, 9);

    long id;
    long lat;
    long lon;

    foreach (_; 0 .. group.dense.nodeCount)
    {
        long idDelta;
        long latDelta;
        long lonDelta;
        bool hasId;
        bool hasLat;
        bool hasLon;

        if (!ids.next(idDelta, hasId, status) ||
            !lats.next(latDelta, hasLat, status) ||
            !lons.next(lonDelta, hasLon, status))
            return false;

        if (!hasId || !hasLat || !hasLon)
        {
            status = PbfStatus.failure(PbfError.denseNodeColumnLengthMismatch, 0, 2);
            return false;
        }

        long nextId;
        long nextLat;
        long nextLon;
        if (!checkedAdd(id, idDelta, nextId))
        {
            status = PbfStatus.failure(PbfError.denseNodeDeltaOverflow, 0, 1);
            return false;
        }
        if (!checkedAdd(lat, latDelta, nextLat))
        {
            status = PbfStatus.failure(PbfError.denseNodeDeltaOverflow, 0, 8);
            return false;
        }
        if (!checkedAdd(lon, lonDelta, nextLon))
        {
            status = PbfStatus.failure(PbfError.denseNodeDeltaOverflow, 0, 9);
            return false;
        }

        id = nextId;
        lat = nextLat;
        lon = nextLon;

        long latNano;
        long lonNano;
        if (!checkedMulAdd(block.latOffset, cast(long)block.granularity, lat, latNano))
        {
            status = PbfStatus.failure(PbfError.denseNodeCoordinateOverflow, 0, 8);
            return false;
        }
        if (!checkedMulAdd(block.lonOffset, cast(long)block.granularity, lon, lonNano))
        {
            status = PbfStatus.failure(PbfError.denseNodeCoordinateOverflow, 0, 9);
            return false;
        }

        DenseTagRange tags;
        if (!tagNodes.nextNode(tags, status))
            return false;

        summary.tagCount += tags.length;
        sink.put(DenseNodeView(id, latNano, lonNano, tags));
        ++summary.nodeCount;
    }

    long ignored;
    bool hasExtra;
    if (!ids.next(ignored, hasExtra, status))
        return false;
    if (hasExtra)
    {
        status = PbfStatus.failure(PbfError.denseNodeColumnLengthMismatch, 0, 1);
        return false;
    }
    if (!lats.next(ignored, hasExtra, status))
        return false;
    if (hasExtra)
    {
        status = PbfStatus.failure(PbfError.denseNodeColumnLengthMismatch, 0, 8);
        return false;
    }
    if (!lons.next(ignored, hasExtra, status))
        return false;
    if (hasExtra)
    {
        status = PbfStatus.failure(PbfError.denseNodeColumnLengthMismatch, 0, 9);
        return false;
    }

    if (!tagNodes.finish(status))
        return false;
    if (summary.tagCount != tagValidation.tagCount)
    {
        status = PbfStatus.failure(PbfError.denseTagNodeCountMismatch, 0, 10);
        return false;
    }

    status = PbfStatus.init;
    return true;
}

private bool preflightCoordinates(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    out PbfStatus status)
    @safe pure nothrow @nogc
{
    long ignored;
    const factor = cast(long)block.granularity;

    if (group.dense.hasLatRange)
    {
        if (!checkedMulAdd(block.latOffset, factor, group.dense.minLat, ignored) ||
            !checkedMulAdd(block.latOffset, factor, group.dense.maxLat, ignored))
        {
            status = PbfStatus.failure(PbfError.denseNodeCoordinateOverflow, 0, 8);
            return false;
        }
    }

    if (group.dense.hasLonRange)
    {
        if (!checkedMulAdd(block.lonOffset, factor, group.dense.minLon, ignored) ||
            !checkedMulAdd(block.lonOffset, factor, group.dense.maxLon, ignored))
        {
            status = PbfStatus.failure(PbfError.denseNodeCoordinateOverflow, 0, 9);
            return false;
        }
    }

    status = PbfStatus.init;
    return true;
}

private struct DenseColumnCursor
{
private:
    WireCursor _group;
    WireCursor _dense;
    WireCursor _packed;
    size_t _denseBase;
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
                if (!readSVarint64(_packed, value, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = _fieldNumber;
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

                if (field.number == _fieldNumber && field.wireType == WireType.varint)
                {
                    if (!readSVarint64(_dense, value, wire))
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

                if (field.number == _fieldNumber &&
                    field.wireType == WireType.lengthDelimited)
                {
                    const(ubyte)[] packed;
                    if (!readLengthDelimited(_dense, field.number, packed, wire))
                    {
                        status = PbfStatus.fromDenseNodesWire(wire, _denseBase);
                        return false;
                    }
                    _packedBase = _denseBase + _dense.offset - packed.length;
                    _packed = WireCursor(packed);
                    break;
                }

                if (!skipFieldValue(_dense, field, wire))
                {
                    status = PbfStatus.fromDenseNodesWire(wire, _denseBase);
                    return false;
                }
            }

            if (!_packed.empty)
                continue;

            if (!_dense.empty)
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
    const(ubyte)[] groupBytes = [
        0x12, 0x14,
        0x0a, 0x04, 0xc8, 0x01, 0x04, 0x01,
        0x2a, 0x00,
        0x42, 0x03, 0x14, 0x02, 0x03,
        0x4a, 0x03, 0x28, 0x01, 0x06,
        0x52, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    block.granularity = 100;
    block.latOffset = 1000;
    block.lonOffset = -1000;

    import osm.io.pbf.string_table : StringRef;
    const(ubyte)[] stringBytes = [0];
    StringRef[1] stringRefs = [StringRef(0, 0)];
    StringTableView table = StringTableView(stringBytes, stringRefs[]);

    struct Sink
    {
        DenseNodeView[3] nodes;
        size_t used;

        void put(DenseNodeView node) @safe nothrow @nogc
        {
            nodes[used++] = node;
        }
    }

    Sink sink;
    DenseNodeDecodeSummary summary;
    assert(decodeDenseNodes(block, group, table, sink, summary, status));
    assert(status.ok);
    assert(summary.nodeCount == 3);
    assert(summary.tagCount == 0);
    assert(sink.used == 3);
    assert(sink.nodes[0].id == 100 && sink.nodes[0].latNano == 2000 && sink.nodes[0].lonNano == 1000);
    assert(sink.nodes[1].id == 102 && sink.nodes[1].latNano == 2100 && sink.nodes[1].lonNano == 900);
    assert(sink.nodes[2].id == 101 && sink.nodes[2].latNano == 1900 && sink.nodes[2].lonNano == 1200);
    assert(sink.nodes[0].tags.empty && sink.nodes[1].tags.empty && sink.nodes[2].tags.empty);
}

unittest
{
    // Coordinate overflow is detected before the sink receives any node.
    const(ubyte)[] groupBytes = [
        0x12, 0x06,
        0x08, 0x02,
        0x40, 0x02,
        0x48, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    block.granularity = 2;
    block.latOffset = long.max;

    import osm.io.pbf.string_table : StringRef;
    const(ubyte)[] stringBytes = [0];
    StringRef[1] stringRefs = [StringRef(0, 0)];
    StringTableView table = StringTableView(stringBytes, stringRefs[]);

    struct CountingSink
    {
        size_t used;
        void put(DenseNodeView) @safe nothrow @nogc { ++used; }
    }

    CountingSink sink;
    DenseNodeDecodeSummary summary;
    assert(!decodeDenseNodes(block, group, table, sink, summary, status));
    assert(status.error == PbfError.denseNodeCoordinateOverflow);
    assert(sink.used == 0);
}


unittest
{
    // Tags are prevalidated and exposed in original key/value order.
    const(ubyte)[] groupBytes = [
        0x12, 0x14,
        0x0a, 0x02, 0x02, 0x02,
        0x42, 0x02, 0x02, 0x02,
        0x4a, 0x02, 0x02, 0x02,
        0x52, 0x06, 0x01, 0x02, 0x03, 0x04, 0x00, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    block.granularity = 100;

    import osm.io.pbf.string_table : StringRef;
    const(ubyte)[] stringBytes = [0, 'a', '1', 'b', '2'];
    StringRef[5] refs = [
        StringRef(0, 0),
        StringRef(1, 1),
        StringRef(2, 1),
        StringRef(3, 1),
        StringRef(4, 1),
    ];
    StringTableView table = StringTableView(stringBytes, refs[]);

    struct Sink
    {
        size_t used;
        size_t firstNodeTags;
        const(ubyte)[] firstKey;
        const(ubyte)[] secondKey;

        void put(DenseNodeView node) @safe nothrow @nogc
        {
            if (used == 0)
            {
                auto tags = node.tags;
                firstNodeTags = tags.length;
                if (!tags.empty)
                {
                    firstKey = tags.front.key;
                    tags.popFront();
                }
                if (!tags.empty)
                    secondKey = tags.front.key;
            }
            else
                assert(node.tags.empty);
            ++used;
        }
    }

    Sink sink;
    DenseNodeDecodeSummary summary;
    assert(decodeDenseNodes(block, group, table, sink, summary, status));
    assert(summary.nodeCount == 2);
    assert(summary.tagCount == 2);
    assert(sink.used == 2);
    assert(sink.firstNodeTags == 2);
    const(ubyte)[] a = ['a'];
    const(ubyte)[] b = ['b'];
    assert(sink.firstKey == a);
    assert(sink.secondKey == b);
}


unittest
{
    // Tag preflight failure occurs before the sink receives a node.
    const(ubyte)[] groupBytes = [
        0x12, 0x0e,
        0x0a, 0x01, 0x02,
        0x42, 0x01, 0x02,
        0x4a, 0x01, 0x02,
        0x52, 0x03, 0x03, 0x02, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    block.granularity = 100;

    import osm.io.pbf.string_table : StringRef;
    const(ubyte)[] stringBytes = [0, 'k', 'v'];
    StringRef[3] refs = [StringRef(0, 0), StringRef(1, 1), StringRef(2, 1)];
    StringTableView table = StringTableView(stringBytes, refs[]);

    struct CountingSink
    {
        size_t used;
        void put(DenseNodeView) @safe nothrow @nogc { ++used; }
    }

    CountingSink sink;
    DenseNodeDecodeSummary summary;
    assert(!decodeDenseNodes(block, group, table, sink, summary, status));
    assert(status.error == PbfError.denseTagStringIdOutOfRange);
    assert(sink.used == 0);
}
