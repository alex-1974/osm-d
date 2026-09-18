/**
 * Structural validation and layout discovery for OSMPBF `PrimitiveGroup` data.
 *
 * The decoder keeps primitive payloads borrowed from the original group and
 * validates DenseNodes column structure without allocating. Dense node ID,
 * latitude and longitude streams accept both packed and unpacked protobuf
 * encodings and merge repeated DenseNodes message occurrences according to
 * protobuf message semantics.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.primitive_group;

import osm.io.pbf.error : PbfError, PbfStatus;
import osm.util.checked : checkedAdd;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;
import osm.wire.varint : readSVarint64, readVarint64;

/** Validated DenseNodes metadata discovered inside one PrimitiveGroup. */
struct DenseNodesLayout
{
    /// Number of serialized DenseNodes message occurrences merged by protobuf.
    size_t occurrences;
    /// Number of decoded delta values in the merged ID column.
    size_t idCount;
    /// Number of decoded delta values in the merged latitude column.
    size_t latCount;
    /// Number of decoded delta values in the merged longitude column.
    size_t lonCount;
    /// Number of DenseInfo message occurrences encountered.
    size_t denseInfoOccurrences;
    /// Number of correctly encoded `keys_vals` field occurrences.
    size_t keysValsOccurrences;
    /// Number of encoded `keys_vals` integers, packed or unpacked.
    size_t keysValsCount;
    /// Final cumulative ID after applying every validated delta.
    long finalId;
    /// Final cumulative latitude grid value after all validated deltas.
    long finalLat;
    /// Final cumulative longitude grid value after all validated deltas.
    long finalLon;
    /// Minimum cumulative latitude grid value seen in the merged stream.
    long minLat;
    /// Maximum cumulative latitude grid value seen in the merged stream.
    long maxLat;
    /// Minimum cumulative longitude grid value seen in the merged stream.
    long minLon;
    /// Maximum cumulative longitude grid value seen in the merged stream.
    long maxLon;
    /// Whether at least one latitude value established the min/max range.
    bool hasLatRange;
    /// Whether at least one longitude value established the min/max range.
    bool hasLonRange;

    // The remaining six tail-padding bytes cache the sole DenseNodes payload
    // without increasing DenseNodesLayout. Values that do not fit 24 bits are
    // intentionally left uncached and use the generic decoder path.
    private ubyte[3] densePayloadOffset24;
    private ubyte[3] densePayloadLength24;

    /** Byte offset of the reusable sole DenseNodes payload, or zero if absent. */
    @property uint densePayloadOffset() const @safe pure nothrow @nogc
    {
        return cast(uint)densePayloadOffset24[0] |
            (cast(uint)densePayloadOffset24[1] << 8) |
            (cast(uint)densePayloadOffset24[2] << 16);
    }

    /** Byte length of the reusable sole DenseNodes payload. */
    @property uint densePayloadLength() const @safe pure nothrow @nogc
    {
        return cast(uint)densePayloadLength24[0] |
            (cast(uint)densePayloadLength24[1] << 8) |
            (cast(uint)densePayloadLength24[2] << 16);
    }

    private void setDensePayloadCache(uint offset, uint length)
        @safe pure nothrow @nogc
    {
        densePayloadOffset24[0] = cast(ubyte)offset;
        densePayloadOffset24[1] = cast(ubyte)(offset >> 8);
        densePayloadOffset24[2] = cast(ubyte)(offset >> 16);

        densePayloadLength24[0] = cast(ubyte)length;
        densePayloadLength24[1] = cast(ubyte)(length >> 8);
        densePayloadLength24[2] = cast(ubyte)(length >> 16);
    }

    private void clearDensePayloadCache()
        @safe pure nothrow @nogc
    {
        densePayloadOffset24[] = 0;
        densePayloadLength24[] = 0;
    }

    /** Returns the validated number of dense nodes in the group. */
    @property size_t nodeCount() const @safe pure nothrow @nogc
    {
        return idCount;
    }

    /** Returns `true` when a DenseInfo message is present. */
    @property bool hasDenseInfo() const @safe pure nothrow @nogc
    {
        return denseInfoOccurrences != 0;
    }

    /** Returns `true` when at least one `keys_vals` field is present. */
    @property bool hasKeysVals() const @safe pure nothrow @nogc
    {
        return keysValsOccurrences != 0;
    }
}

static if (size_t.sizeof == 8)
{
    // A8 payload reuse deliberately occupies the six bytes that were tail
    // padding after the two range-presence flags on the 64-bit layout.
    static assert(DenseNodesLayout.sizeof == 120);
    static assert(DenseNodesLayout.alignof == 8);
    static assert(DenseNodesLayout.hasLatRange.offsetof == 112);
    static assert(DenseNodesLayout.hasLonRange.offsetof == 113);
    static assert(DenseNodesLayout.densePayloadOffset24.offsetof == 114);
    static assert(DenseNodesLayout.densePayloadLength24.offsetof == 117);
}

/** Allocation-free structural layout of one serialized PrimitiveGroup. */
struct PrimitiveGroupLayout
{
    /// Complete serialized PrimitiveGroup bytes.
    const(ubyte)[] raw;
    /// Number of Node message occurrences.
    size_t nodeOccurrences;
    /// Merged DenseNodes layout and validation metadata.
    DenseNodesLayout dense;
    /// Number of Way message occurrences.
    size_t wayOccurrences;
    /// Number of Relation message occurrences.
    size_t relationOccurrences;
    /// Number of legacy ChangeSet message occurrences.
    size_t changeSetOccurrences;

    /** Returns `true` when this group contains DenseNodes data. */
    @property bool hasDenseNodes() const @safe pure nothrow @nogc
    {
        return dense.occurrences != 0;
    }
}

/**
 * Decode and validate one complete serialized OSMPBF `PrimitiveGroup`.
 *
 * Known primitive message fields are counted only when they use their schema
 * wire type (`length-delimited`). A group containing more than one primitive
 * kind is rejected because the OSMPBF schema requires all primitives in one
 * group to have the same type. DenseNodes messages are merged across repeated
 * occurrences. Their ID/lat/lon and keys_vals columns accept both canonical
 * packed encoding and legal unpacked protobuf representation.
 *
 * Dense delta accumulation is checked during this first pass, before any node
 * can be emitted to a consumer. DenseInfo is not interpreted semantically yet,
 * but every occurrence is scanned as a structurally valid protobuf submessage.
 *
 * Params:
 *   input = Complete serialized PrimitiveGroup payload.
 *   layout = Receives the borrowed validated group layout.
 *   status = Receives success or a precise structural/wire failure.
 *
 * Returns:
 *   `true` for a structurally valid group; `false` otherwise.
 */
bool decodePrimitiveGroupLayout(
    const(ubyte)[] input,
    out PrimitiveGroupLayout layout,
    out PbfStatus status)
    @safe nothrow @nogc
{
    layout = PrimitiveGroupLayout.init;
    layout.raw = input;

    auto cursor = WireCursor(input);
    ubyte primitiveKind;

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromPrimitiveGroupWire(wire);
            return false;
        }

        if (field.number >= 1 && field.number <= 5 &&
            field.wireType == WireType.lengthDelimited)
        {
            const(ubyte)[] payload;
            if (!readLengthDelimited(cursor, field.number, payload, wire))
            {
                status = PbfStatus.fromPrimitiveGroupWire(wire);
                return false;
            }

            const kind = cast(ubyte)field.number;
            if (primitiveKind == 0)
                primitiveKind = kind;
            else if (primitiveKind != kind)
            {
                status = PbfStatus.failure(
                    PbfError.mixedPrimitiveGroupTypes,
                    field.offset,
                    field.number);
                return false;
            }

            switch (field.number)
            {
                case 1:
                    ++layout.nodeOccurrences;
                    break;
                case 2:
                    ++layout.dense.occurrences;
                    const payloadOffset = cursor.offset - payload.length;

                    if (!scanDenseNodes(payload, payloadOffset, layout.dense, status))
                        return false;

                    // Reuse the already-decoded outer DenseNodes payload only
                    // for the format-defined implicit-all-tagless representation:
                    // an entirely empty logical keys_vals stream. A non-empty
                    // keys_vals stream may still validate to zero actual tags
                    // when it contains only node delimiters; that legal form
                    // intentionally falls back to the generic coordinate cursor
                    // rather than adding tag-value semantics to this layout scan.
                    //
                    // Repeated DenseNodes messages require protobuf merging and
                    // therefore also use the generic path. Larger valid spans
                    // remain supported when the 24-bit cache cannot represent
                    // their offset or length.
                    enum size_t maxDensePayloadCacheValue = 0xFF_FF_FF;
                    if (layout.dense.occurrences == 1)
                    {
                        if (layout.dense.keysValsCount == 0 &&
                            payloadOffset <= maxDensePayloadCacheValue &&
                            payload.length <= maxDensePayloadCacheValue)
                        {
                            layout.dense.setDensePayloadCache(
                                cast(uint)payloadOffset,
                                cast(uint)payload.length);
                        }
                    }
                    else
                    {
                        // A later DenseNodes occurrence invalidates any span
                        // cached from the first occurrence because protobuf
                        // message fields merge logically across occurrences.
                        layout.dense.clearDensePayloadCache();
                    }
                    break;
                case 3:
                    ++layout.wayOccurrences;
                    break;
                case 4:
                    ++layout.relationOccurrences;
                    break;
                case 5:
                    ++layout.changeSetOccurrences;
                    break;
                default:
                    assert(0, "unreachable PrimitiveGroup field");
            }
            continue;
        }

        if (!skipFieldValue(cursor, field, wire))
        {
            status = PbfStatus.fromPrimitiveGroupWire(wire);
            return false;
        }
    }

    if (layout.hasDenseNodes &&
        (layout.dense.idCount != layout.dense.latCount ||
         layout.dense.idCount != layout.dense.lonCount))
    {
        status = PbfStatus.failure(PbfError.denseNodeColumnLengthMismatch, 0, 2);
        return false;
    }

    status = PbfStatus.init;
    return true;
}

private bool scanDenseNodes(
    const(ubyte)[] input,
    size_t baseOffset,
    ref DenseNodesLayout layout,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto cursor = WireCursor(input);

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromDenseNodesWire(wire, baseOffset);
            return false;
        }

        if (field.number == 1 || field.number == 8 || field.number == 9)
        {
            if (field.wireType == WireType.varint)
            {
                long delta;
                if (!readSVarint64(cursor, delta, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = field.number;
                    status = PbfStatus.fromDenseNodesWire(wire, baseOffset);
                    return false;
                }
                if (!acceptDenseDelta(field.number, delta, baseOffset + field.offset,
                    layout, status))
                    return false;
                continue;
            }

            if (field.wireType == WireType.lengthDelimited)
            {
                const(ubyte)[] packed;
                if (!readLengthDelimited(cursor, field.number, packed, wire))
                {
                    status = PbfStatus.fromDenseNodesWire(wire, baseOffset);
                    return false;
                }

                const packedOffset = baseOffset + cursor.offset - packed.length;
                if (!scanPackedSInt64(
                    packed,
                    packedOffset,
                    field.number,
                    layout,
                    status))
                    return false;
                continue;
            }
        }

        if (field.number == 5 && field.wireType == WireType.lengthDelimited)
        {
            const(ubyte)[] denseInfo;
            if (!readLengthDelimited(cursor, field.number, denseInfo, wire))
            {
                status = PbfStatus.fromDenseNodesWire(wire, baseOffset);
                return false;
            }

            const infoOffset = baseOffset + cursor.offset - denseInfo.length;
            if (!validateDenseInfo(denseInfo, infoOffset, status))
                return false;
            ++layout.denseInfoOccurrences;
            continue;
        }

        if (field.number == 10)
        {
            if (field.wireType == WireType.varint)
            {
                ++layout.keysValsOccurrences;
                ulong ignored;
                if (!readVarint64(cursor, ignored, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = field.number;
                    status = PbfStatus.fromDenseNodesWire(wire, baseOffset);
                    return false;
                }
                ++layout.keysValsCount;
                continue;
            }

            if (field.wireType == WireType.lengthDelimited)
            {
                ++layout.keysValsOccurrences;
                const(ubyte)[] packed;
                if (!readLengthDelimited(cursor, field.number, packed, wire))
                {
                    status = PbfStatus.fromDenseNodesWire(wire, baseOffset);
                    return false;
                }

                auto packedCursor = WireCursor(packed);
                const packedOffset = baseOffset + cursor.offset - packed.length;
                while (!packedCursor.empty)
                {
                    ulong ignored;
                    if (!readVarint64(packedCursor, ignored, wire))
                    {
                        if (wire.fieldNumber == 0)
                            wire.fieldNumber = field.number;
                        status = PbfStatus.fromDenseNodesWire(wire, packedOffset);
                        return false;
                    }
                    ++layout.keysValsCount;
                }
                continue;
            }
        }

        if (!skipFieldValue(cursor, field, wire))
        {
            status = PbfStatus.fromDenseNodesWire(wire, baseOffset);
            return false;
        }
    }

    status = PbfStatus.init;
    return true;
}

private bool scanPackedSInt64(
    const(ubyte)[] packed,
    size_t baseOffset,
    uint fieldNumber,
    ref DenseNodesLayout layout,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto cursor = WireCursor(packed);
    while (!cursor.empty)
    {
        const valueOffset = baseOffset + cursor.offset;
        WireStatus wire;
        long delta;
        if (!readSVarint64(cursor, delta, wire))
        {
            if (wire.fieldNumber == 0)
                wire.fieldNumber = fieldNumber;
            status = PbfStatus.fromDenseNodesWire(wire, baseOffset);
            return false;
        }

        if (!acceptDenseDelta(fieldNumber, delta, valueOffset, layout, status))
            return false;
    }

    status = PbfStatus.init;
    return true;
}

private bool acceptDenseDelta(
    uint fieldNumber,
    long delta,
    size_t offset,
    ref DenseNodesLayout layout,
    out PbfStatus status)
    @safe nothrow @nogc
{
    long next;
    switch (fieldNumber)
    {
        case 1:
            if (!checkedAdd(layout.finalId, delta, next))
            {
                status = PbfStatus.failure(
                    PbfError.denseNodeDeltaOverflow, offset, fieldNumber);
                return false;
            }
            layout.finalId = next;
            ++layout.idCount;
            break;

        case 8:
            if (!checkedAdd(layout.finalLat, delta, next))
            {
                status = PbfStatus.failure(
                    PbfError.denseNodeDeltaOverflow, offset, fieldNumber);
                return false;
            }
            layout.finalLat = next;
            if (!layout.hasLatRange)
            {
                layout.minLat = next;
                layout.maxLat = next;
                layout.hasLatRange = true;
            }
            else
            {
                if (next < layout.minLat)
                    layout.minLat = next;
                if (next > layout.maxLat)
                    layout.maxLat = next;
            }
            ++layout.latCount;
            break;

        case 9:
            if (!checkedAdd(layout.finalLon, delta, next))
            {
                status = PbfStatus.failure(
                    PbfError.denseNodeDeltaOverflow, offset, fieldNumber);
                return false;
            }
            layout.finalLon = next;
            if (!layout.hasLonRange)
            {
                layout.minLon = next;
                layout.maxLon = next;
                layout.hasLonRange = true;
            }
            else
            {
                if (next < layout.minLon)
                    layout.minLon = next;
                if (next > layout.maxLon)
                    layout.maxLon = next;
            }
            ++layout.lonCount;
            break;

        default:
            assert(0, "unexpected DenseNodes delta field");
    }

    status = PbfStatus.init;
    return true;
}

private bool validateDenseInfo(
    const(ubyte)[] input,
    size_t baseOffset,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto cursor = WireCursor(input);
    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromDenseInfoWire(wire, baseOffset);
            return false;
        }

        // DenseInfo fields 1..6 are all packable varint scalar types. Accept
        // both packed and unpacked protobuf forms while validating every
        // encoded scalar, without interpreting metadata semantics yet.
        if (field.number >= 1 && field.number <= 6)
        {
            if (field.wireType == WireType.varint)
            {
                ulong ignored;
                if (!readVarint64(cursor, ignored, wire))
                {
                    if (wire.fieldNumber == 0)
                        wire.fieldNumber = field.number;
                    status = PbfStatus.fromDenseInfoWire(wire, baseOffset);
                    return false;
                }
                continue;
            }

            if (field.wireType == WireType.lengthDelimited)
            {
                const(ubyte)[] packed;
                if (!readLengthDelimited(cursor, field.number, packed, wire))
                {
                    status = PbfStatus.fromDenseInfoWire(wire, baseOffset);
                    return false;
                }

                auto packedCursor = WireCursor(packed);
                const packedOffset = baseOffset + cursor.offset - packed.length;
                while (!packedCursor.empty)
                {
                    ulong ignored;
                    if (!readVarint64(packedCursor, ignored, wire))
                    {
                        if (wire.fieldNumber == 0)
                            wire.fieldNumber = field.number;
                        status = PbfStatus.fromDenseInfoWire(wire, packedOffset);
                        return false;
                    }
                }
                continue;
            }
        }

        if (!skipFieldValue(cursor, field, wire))
        {
            status = PbfStatus.fromDenseInfoWire(wire, baseOffset);
            return false;
        }
    }

    status = PbfStatus.init;
    return true;
}

unittest
{
    DenseNodesLayout layout;

    enum uint max24 = 0xFF_FF_FF;
    layout.setDensePayloadCache(max24, max24);

    assert(layout.densePayloadOffset == max24);
    assert(layout.densePayloadLength == max24);

    layout.clearDensePayloadCache();

    assert(layout.densePayloadOffset == 0);
    assert(layout.densePayloadLength == 0);
}

unittest
{
    // Canonical packed DenseNodes: ids 100,102,101; lats 10,11,9; lons 20,19,22.
    const(ubyte)[] group = [
        0x12, 0x14,
        0x0a, 0x04, 0xc8, 0x01, 0x04, 0x01,
        0x2a, 0x00,
        0x42, 0x03, 0x14, 0x02, 0x03,
        0x4a, 0x03, 0x28, 0x01, 0x06,
        0x52, 0x00,
    ];

    PrimitiveGroupLayout layout;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(group, layout, status));
    assert(status.ok);
    assert(layout.hasDenseNodes);
    assert(layout.dense.occurrences == 1);
    assert(layout.dense.densePayloadOffset == 2);
    assert(layout.dense.densePayloadLength == 0x14);
    assert(layout.dense.nodeCount == 3);
    assert(layout.dense.finalId == 101);
    assert(layout.dense.finalLat == 9);
    assert(layout.dense.finalLon == 22);
    assert(layout.dense.minLat == 9 && layout.dense.maxLat == 11);
    assert(layout.dense.minLon == 19 && layout.dense.maxLon == 22);
    assert(layout.dense.hasDenseInfo);
    assert(layout.dense.hasKeysVals);
    assert(layout.dense.keysValsCount == 0);
}

unittest
{
    // A non-empty keys_vals stream can still describe zero actual tags when
    // every value is a node delimiter. Payload reuse deliberately leaves that
    // representation uncached so layout discovery need not duplicate tag
    // semantics merely to decide whether the coordinate cache is profitable.
    const(ubyte)[] group = [
        0x12, 0x10,
        0x0a, 0x02, 0x02, 0x02,
        0x42, 0x02, 0x02, 0x02,
        0x4a, 0x02, 0x02, 0x02,
        0x52, 0x02, 0x00, 0x00,
    ];

    PrimitiveGroupLayout layout;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(group, layout, status));
    assert(status.ok);
    assert(layout.dense.nodeCount == 2);
    assert(layout.dense.keysValsCount == 2);
    assert(layout.dense.densePayloadOffset == 0);
    assert(layout.dense.densePayloadLength == 0);
}

unittest
{
    // Legal unpacked fields and repeated DenseNodes message occurrences merge.
    const(ubyte)[] group = [
        0x12, 0x06, 0x08, 0x02, 0x40, 0x0a, 0x48, 0x05,
        0x12, 0x06, 0x08, 0x04, 0x40, 0x01, 0x48, 0x04,
    ];

    PrimitiveGroupLayout layout;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(group, layout, status));
    assert(layout.dense.occurrences == 2);
    assert(layout.dense.densePayloadOffset == 0);
    assert(layout.dense.densePayloadLength == 0);
    assert(layout.dense.nodeCount == 2);
    assert(layout.dense.finalId == 3);
    assert(layout.dense.finalLat == 4);
    assert(layout.dense.finalLon == -1);
}

unittest
{
    PrimitiveGroupLayout layout;
    PbfStatus status;

    // Dense plus Way in the same PrimitiveGroup violates the schema contract.
    const(ubyte)[] mixed = [0x12, 0x00, 0x1a, 0x00];
    assert(!decodePrimitiveGroupLayout(mixed, layout, status));
    assert(status.error == PbfError.mixedPrimitiveGroupTypes);

    // id has two values, lat one, lon two.
    const(ubyte)[] mismatch = [
        0x12, 0x0b,
        0x0a, 0x02, 0x02, 0x02,
        0x42, 0x01, 0x02,
        0x4a, 0x02, 0x02, 0x02,
    ];
    assert(!decodePrimitiveGroupLayout(mismatch, layout, status));
    assert(status.error == PbfError.denseNodeColumnLengthMismatch);
}

unittest
{
    // Multiple packed segments for the same packable repeated fields concatenate.
    const(ubyte)[] group = [
        0x12, 0x16,
        0x0a, 0x01, 0x02,
        0x42, 0x01, 0x04,
        0x4a, 0x01, 0x06,
        0x0a, 0x01, 0x04,
        0x42, 0x01, 0x02,
        0x4a, 0x01, 0x01,
        0x52, 0x02, 0x02, 0x00,
    ];

    PrimitiveGroupLayout layout;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(group, layout, status));
    assert(layout.dense.nodeCount == 2);
    assert(layout.dense.finalId == 3);
    assert(layout.dense.finalLat == 3);
    assert(layout.dense.finalLon == 2);
    assert(layout.dense.keysValsCount == 2);
}

unittest
{
    // long.max followed by +1 must fail checked delta accumulation.
    const(ubyte)[] group = [
        0x12, 0x15,
        0x0a, 0x0b,
        0xfe, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
        0x02,
        0x42, 0x02, 0x00, 0x00,
        0x4a, 0x02, 0x00, 0x00,
    ];

    PrimitiveGroupLayout layout;
    PbfStatus status;
    assert(!decodePrimitiveGroupLayout(group, layout, status));
    assert(status.error == PbfError.denseNodeDeltaOverflow);
    assert(status.fieldNumber == 1);
}

unittest
{
    // DenseInfo packed scalar payload contains a truncated varint.
    const(ubyte)[] group = [
        0x12, 0x05,
        0x2a, 0x03, 0x0a, 0x01, 0x80,
    ];

    PrimitiveGroupLayout layout;
    PbfStatus status;
    assert(!decodePrimitiveGroupLayout(group, layout, status));
    assert(status.error == PbfError.invalidDenseInfoWire);
}
