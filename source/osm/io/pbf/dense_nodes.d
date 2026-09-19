/**
 * Streaming decode of validated OSMPBF DenseNodes coordinates and tags.
 *
 * Dense node IDs, latitudes and longitudes are delta-coded sint64 streams.
 * This module consumes a previously validated `PrimitiveGroupLayout`, performs
 * exact checked nanodegree coordinate conversion, validates DenseInfo and the
 * complete dense tag stream, and emits borrowed-value node views through a
 * statically dispatched sink.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.dense_nodes;

import osm.view.element : ElementType, isElementView;
import osm.io.pbf.dense_info :
    DenseInfoNodeCursor,
    DenseInfoValidationSummary,
    DenseInfoView,
    validateDenseInfo;
import osm.io.pbf.dense_tags :
    DenseTagNodeCursor,
    DenseTagRange,
    DenseTagValidationSummary,
    validateDenseTags;
import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.primitive_block : PrimitiveBlockLayout;
import osm.io.pbf.primitive_group : PrimitiveGroupLayout;
import osm.io.pbf.string_table : StringTableView;
import osm.util.checked : checkedMulAdd;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;
import osm.wire.varint : readSVarint64FailureOnly;

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
    /// Optional decoded metadata from the DenseInfo columns.
    DenseInfoView info;

    /// Semantic OSM element kind, independent of DenseNodes encoding.
    @property ElementType type() const scope
        @safe pure nothrow @nogc
    {
        return ElementType.node;
    }
}

static assert(isElementView!DenseNodeView);

/**
 * Summary of one successfully completed DenseNodes decode operation.
 *
 * The fields are contractually valid only when `decodeDenseNodes` returns
 * `true`. Callers must not interpret their contents as partial progress after
 * a failed decode.
 */
struct DenseNodeDecodeSummary
{
    /// Number of nodes delivered to the sink by the completed decode.
    size_t nodeCount;
    /// Number of ordered tags exposed across all nodes of the completed decode.
    size_t tagCount;
}

/**
 * Decode validated DenseNodes coordinates, metadata, and tags into a static sink.
 *
 * `group` must have been produced by `decodePrimitiveGroupLayout`, and
 * `table` must be the StringTable view built from the same PrimitiveBlock.
 * Before the first sink call, coordinate conversion plus the complete DenseInfo
 * and dense-tag streams are preflighted, so malformed metadata/tag structure,
 * invalid string IDs, or arithmetic overflow cannot be discovered only after a
 * node prefix was already emitted.
 *
 * The sink must provide a compatible `put` overload and itself satisfy the
 * `@safe nothrow @nogc` contract required by this function instantiation.
 * Performance-sensitive sinks that consume the mutable tag input range should
 * accept `scope ref DenseNodeView` so the callback-scoped borrowed view is not
 * copied. The view is intentionally non-const because advancing
 * `DenseTagRange` mutates its cursor state; an existing by-value
 * `put(DenseNodeView)` remains source-compatible.
 *
 * As an optional zero-overhead hook, a sink may additionally provide
 * `putDenseNodeScalars(long id, long latNano, long lonNano)`. That overload is
 * selected only after complete preflight when the DenseNodes sequence contains
 * neither tags nor DenseInfo; otherwise normal `put(DenseNodeView)` delivery is
 * used. The hook therefore changes neither validation nor observable OSM data.
 *
 * Params:
 *   block = Validated PrimitiveBlock layout providing granularity and offsets.
 *   group = Validated PrimitiveGroup layout containing DenseNodes data.
 *   table = Indexed StringTable belonging to `block`.
 *   sink = Consumer receiving nodes in merged protobuf column order.
 *   summary = Receives completed decode counts on success; its contents are not
 *     contractually defined after a `false` return.
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

    if (!preflightCoordinates(block, group, status))
        return false;

    DenseInfoValidationSummary infoValidation;
    if (!validateDenseInfo(block, group, table, infoValidation, status))
        return false;

    DenseTagValidationSummary tagValidation;
    if (!validateDenseTags(group, table, tagValidation, status))
        return false;

    const hasTags = tagValidation.tagCount != 0;
    const hasInfo = infoValidation.hasVersion ||
        infoValidation.hasTimestamp ||
        infoValidation.hasChangeset ||
        infoValidation.hasUid ||
        infoValidation.hasUser ||
        infoValidation.hasVisible;

    if (hasTags)
    {
        if (hasInfo)
            return dispatchDenseNodes!(true, true)(
                block, group, table, tagValidation, infoValidation,
                sink, summary, status);
        return dispatchDenseNodes!(true, false)(
            block, group, table, tagValidation, infoValidation,
            sink, summary, status);
    }

    if (hasInfo)
        return dispatchDenseNodes!(false, true)(
            block, group, table, tagValidation, infoValidation,
            sink, summary, status);
    return dispatchDenseNodes!(false, false)(
        block, group, table, tagValidation, infoValidation,
        sink, summary, status);
}

/**
 * Dispatch to one compile-time-specialized DenseNodes emitter.
 *
 * This wrapper is intentionally not inlined into `decodeDenseNodes`: keeping
 * the four runtime-selected capability variants out of the dispatcher avoids
 * code-size explosion there. The selected `emitDenseNodes` specialization is
 * still forced inline into this wrapper so its hot loop retains cross-function
 * optimization and scalar replacement opportunities.
 */
pragma(inline, false)
private bool dispatchDenseNodes(bool HasTags, bool HasInfo, Sink)(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    DenseTagValidationSummary tagValidation,
    DenseInfoValidationSummary infoValidation,
    ref Sink sink,
    ref DenseNodeDecodeSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    return emitDenseNodes!(HasTags, HasInfo)(
        block, group, table, tagValidation, infoValidation,
        sink, summary, status);
}

/**
 * Emit one completely prevalidated DenseNodes sequence.
 *
 * `HasTags` and `HasInfo` are compile-time capabilities derived from the
 * completed preflight summaries. The false variants remove their cursor work
 * from the per-node loop entirely; they do not skip validation.
 */
pragma(inline, true)
private bool emitDenseNodes(bool HasTags, bool HasInfo, Sink)(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    DenseTagValidationSummary tagValidation,
    DenseInfoValidationSummary infoValidation,
    ref Sink sink,
    ref DenseNodeDecodeSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    static if (HasTags)
        DenseTagNodeCursor tagNodes = DenseTagNodeCursor(group, table);
    static if (HasInfo)
        DenseInfoNodeCursor infoNodes = DenseInfoNodeCursor(
            block, group, table, infoValidation);

    static if (HasTags)
    {
        DenseColumnCursor ids = DenseColumnCursor(group.raw, 1);
        DenseColumnCursor lats = DenseColumnCursor(group.raw, 8);
        DenseColumnCursor lons = DenseColumnCursor(group.raw, 9);
    }
    else
    {
        DenseColumnCursor ids = DenseColumnCursor(group, 1);
        DenseColumnCursor lats = DenseColumnCursor(group, 8);
        DenseColumnCursor lons = DenseColumnCursor(group, 9);
    }

    long id;
    long lat;
    long lon;

    // preflightCoordinates() has already proved that the affine coordinate
    // transform is representable for the complete validated latitude and
    // longitude ranges. Every emitted cumulative coordinate lies within those
    // ranges, so repeating checkedMulAdd for every node is redundant.
    const coordinateFactor = cast(long)block.granularity;

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

        // decodePrimitiveGroupLayout() has already checked every cumulative
        // ID/latitude/longitude delta step over these same validated column
        // streams. Repeating checkedAdd during emission is therefore redundant.
        id += idDelta;
        lat += latDelta;
        lon += lonDelta;

        const latNano = block.latOffset + coordinateFactor * lat;
        const lonNano = block.lonOffset + coordinateFactor * lon;

        static if (!HasTags && !HasInfo &&
            __traits(compiles, sink.putDenseNodeScalars(id, latNano, lonNano)))
        {
            // Optional sink fast path: once preflight proved that this sequence
            // has neither tags nor DenseInfo, scalar-only consumers do not need
            // a large DenseNodeView or its empty borrowed-range members.
            sink.putDenseNodeScalars(id, latNano, lonNano);
        }
        else
        {
            DenseTagRange tags;
            static if (HasTags)
            {
                // validateDenseTags() already proved StringTable-ID semantics
                // for this same stream/table pair. Retain wire and partition
                // checks without repeating that semantic validation.
                if (!tagNodes.nextPrevalidatedNode(tags, status))
                    return false;
                summary.tagCount += tags.length;
            }

            DenseInfoView info;
            static if (HasInfo)
            {
                if (!infoNodes.nextNode(info, status))
                    return false;
            }

            DenseNodeView node = DenseNodeView(id, latNano, lonNano, tags, info);
            sink.put(node);
        }
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

    static if (HasTags)
    {
        if (!tagNodes.finish(status))
            return false;
    }
    static if (HasInfo)
    {
        if (!infoNodes.finish(status))
            return false;
    }

    if (summary.tagCount != tagValidation.tagCount)
    {
        status = PbfStatus.failure(PbfError.denseTagNodeCountMismatch, 0, 10);
        return false;
    }

    // The validated layout fixes the exact number of nodes before emission.
    // Publish it once after the complete emission succeeds instead of updating
    // the externally visible summary on every node.
    summary.nodeCount = group.dense.nodeCount;

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

    this(ref const PrimitiveGroupLayout group, uint fieldNumber)
        @safe nothrow @nogc
    {
        _fieldNumber = fieldNumber;

        if (group.dense.occurrences == 1 &&
            group.dense.densePayloadOffset != 0)
        {
            const offset = cast(size_t)group.dense.densePayloadOffset;
            const length = cast(size_t)group.dense.densePayloadLength;
            _denseBase = offset;
            _dense = WireCursor(group.raw[offset .. offset + length]);
        }
        else
        {
            _group = WireCursor(group.raw);
        }
    }

    // `status` is failure-only here. The enclosing emitter starts with a
    // successful status and returns immediately after any cursor failure, so
    // rewriting PbfStatus.init for every successfully decoded value is redundant.
    pragma(inline, true)
    bool next(out long value, out bool hasValue, ref PbfStatus status)
        @safe nothrow @nogc
    {
        value = 0;
        hasValue = false;

        while (true)
        {
            if (!_packed.empty)
            {
                WireStatus wire;
                if (!readSVarint64FailureOnly(_packed, value, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = _fieldNumber;
                    status = PbfStatus.fromDenseNodesWire(wire, _packedBase);
                    return false;
                }
                hasValue = true;
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
                    if (!readSVarint64FailureOnly(_dense, value, wire))
                    {
                        if (wire.fieldNumber == 0)
                            wire.fieldNumber = field.number;
                        status = PbfStatus.fromDenseNodesWire(wire, _denseBase);
                        return false;
                    }
                    hasValue = true;
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
                return true;
            }
        }
    }
}

unittest
{
    // Packed and unpacked occurrences of each DenseNodes delta column concatenate
    // in serialized field order. This also covers interleaving with the other
    // coordinate columns.
    //
    // ids:  +1, +2, -1 -> 1, 3, 2
    // lats: +10, -2, +1 -> 10, 8, 9
    // lons: +5, -1, +2 -> 5, 4, 6
    const(ubyte)[] groupBytes = [
        0x12, 0x14,

        0x0a, 0x01, 0x02,
        0x40, 0x14,
        0x4a, 0x02, 0x0a, 0x01,

        0x08, 0x04,
        0x42, 0x02, 0x03, 0x02,
        0x48, 0x04,

        0x0a, 0x01, 0x01,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));
    assert(status.ok);

    assert(group.dense.nodeCount == 3);
    assert(group.dense.finalId == 2);
    assert(group.dense.finalLat == 9);
    assert(group.dense.finalLon == 6);
    assert(group.dense.minLat == 8 && group.dense.maxLat == 10);
    assert(group.dense.minLon == 4 && group.dense.maxLon == 6);

    PrimitiveBlockLayout block;
    block.granularity = 1;

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
    assert(sink.used == 3);

    assert(sink.nodes[0].id == 1);
    assert(sink.nodes[0].latNano == 10);
    assert(sink.nodes[0].lonNano == 5);

    assert(sink.nodes[1].id == 3);
    assert(sink.nodes[1].latNano == 8);
    assert(sink.nodes[1].lonNano == 4);

    assert(sink.nodes[2].id == 2);
    assert(sink.nodes[2].latNano == 9);
    assert(sink.nodes[2].lonNano == 6);
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
    assert(!sink.nodes[0].info.hasVersion && !sink.nodes[0].info.hasTimestamp);
    assert(!sink.nodes[1].info.hasUser && !sink.nodes[2].info.hasVisible);
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

unittest
{
    // DenseInfo metadata reaches the same node view as coordinates and tags.
    const(ubyte)[] groupBytes = [
        0x12, 0x11,
        0x0a, 0x01, 0x02,
        0x2a, 0x06,
        0x0a, 0x01, 0x07,
        0x2a, 0x01, 0x02,
        0x42, 0x01, 0x02,
        0x4a, 0x01, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    block.granularity = 100;

    import osm.io.pbf.string_table : StringRef;
    const(ubyte)[] strings = [0, 'u'];
    StringRef[2] refs = [StringRef(0, 0), StringRef(1, 1)];
    StringTableView table = StringTableView(strings, refs[]);

    struct Sink
    {
        DenseNodeView node;
        size_t used;

        void put(DenseNodeView value) @safe nothrow @nogc
        {
            node = value;
            ++used;
        }
    }

    Sink sink;
    DenseNodeDecodeSummary summary;
    assert(decodeDenseNodes(block, group, table, sink, summary, status));
    assert(summary.nodeCount == 1 && sink.used == 1);
    assert(sink.node.info.hasVersion && sink.node.info.version_ == 7);
    assert(sink.node.info.hasUser && sink.node.info.userSid == 1);
    const(ubyte)[] u = ['u'];
    assert(sink.node.info.user == u);
}


unittest
{
    // A scalar-capable sink bypasses DenseNodeView construction only when the
    // completely prevalidated sequence contains neither tags nor DenseInfo.
    const(ubyte)[] groupBytes = [
        0x12, 0x0c,
        0x0a, 0x02, 0x02, 0x02,
        0x42, 0x02, 0x02, 0x02,
        0x4a, 0x02, 0x02, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    block.granularity = 100;

    import osm.io.pbf.string_table : StringRef;
    const(ubyte)[] stringBytes = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(stringBytes, refs[]);

    struct ScalarSink
    {
        size_t scalarUsed;
        size_t viewUsed;
        long lastId;

        void putDenseNodeScalars(long id, long, long) @safe nothrow @nogc
        {
            ++scalarUsed;
            lastId = id;
        }

        void put(DenseNodeView) @safe nothrow @nogc
        {
            ++viewUsed;
        }
    }

    ScalarSink sink;
    DenseNodeDecodeSummary summary;
    assert(decodeDenseNodes(block, group, table, sink, summary, status));
    assert(status.ok);
    assert(summary.nodeCount == 2 && summary.tagCount == 0);
    assert(sink.scalarUsed == 2 && sink.viewUsed == 0);
    assert(sink.lastId == 2);
}
