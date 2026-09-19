/**
 * Streaming decode of regular OSMPBF `Way` messages.
 *
 * A Way remains an OSM topological object at this layer: it exposes its signed
 * OSM ID, ordered tags, optional Info metadata, and the ordered absolute node
 * IDs reconstructed from the delta-coded `refs` column. Current OSM-binary
 * `LocationsOnWays` latitude/longitude columns are exposed as an optional
 * aligned borrowed range. The Way is deliberately not interpreted as a line or
 * polygon; geometry construction belongs to a higher resolver/geometry layer.
 *
 * Every Way in the PrimitiveGroup is fully preflighted before the first sink
 * call. Repeated refs accept packed and unpacked protobuf encodings, concatenate
 * in wire order, and use checked signed-64-bit delta accumulation.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-13
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.way;

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
import osm.util.checked : checkedAdd, checkedMulAdd;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;
import osm.wire.varint : readSVarint64, readVarint32, readVarint64;

/** Validation summary for one Way's delta-coded node-reference column. */
struct WayRefValidationSummary
{
    /// Number of logical refs after concatenating packed/unpacked occurrences.
    size_t refCount;
    /// Final absolute node ID after checked accumulation of every delta.
    long finalRef;
}

/** Validation summary for optional `LocationsOnWays` latitude/longitude columns. */
struct WayLocationValidationSummary
{
    /// Number of logical latitude deltas.
    size_t latCount;
    /// Number of logical longitude deltas.
    size_t lonCount;
    /// Final cumulative latitude grid value.
    long finalLat;
    /// Final cumulative longitude grid value.
    long finalLon;

    /** Whether this Way carries usable per-reference node locations. */
    @property bool hasLocations() const @safe pure nothrow @nogc
    {
        return latCount != 0 || lonCount != 0;
    }
}

/** Borrowed input range over one validated Way's absolute node references. */
struct WayRefRange
{
private:
    SInt64FieldCursor _deltas;
    long _current;
    long _front;
    size_t _remaining;

public:
    /** Returns `true` when no node reference remains. */
    pragma(inline, true)
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _remaining == 0;
    }

    /** Returns the number of node references not yet consumed. */
    pragma(inline, true)
    @property size_t length() const @safe pure nothrow @nogc
    {
        return _remaining;
    }

    /** Return the current absolute OSM node ID. */
    pragma(inline, true)
    @property long front() const @safe pure nothrow @nogc
    in (!empty)
    {
        return _front;
    }

    /** Advance to the next already validated absolute node ID. */
    pragma(inline, true)
    void popFront() @safe nothrow @nogc
    in (!empty)
    {
        --_remaining;
        if (_remaining == 0)
        {
            _front = 0;
            return;
        }

        long delta;
        bool hasValue;
        PbfStatus ignored;
        if (!_deltas.next(delta, hasValue, ignored) || !hasValue)
        {
            _remaining = 0;
            _front = 0;
            return;
        }

        long next;
        if (!checkedAdd(_current, delta, next))
        {
            // Immutable bytes were completely preflighted before construction.
            _remaining = 0;
            _front = 0;
            return;
        }

        _current = next;
        _front = next;
    }
}

/** Exact borrowed node location aligned with one Way reference. */
struct WayLocationView
{
    /// Exact latitude in nanodegrees.
    long latNano;
    /// Exact longitude in nanodegrees.
    long lonNano;
}

/**
 * Borrowed range over optional `LocationsOnWays` coordinates.
 *
 * When non-empty, this range has exactly the same length and order as
 * `WayView.refs`. Consumers may zip the two ranges without allocation.
 */
struct WayLocationRange
{
private:
    SInt64FieldCursor _lats;
    SInt64FieldCursor _lons;
    long _lat;
    long _lon;
    WayLocationView _front;
    size_t _remaining;
    long _latOffset;
    long _lonOffset;
    int _granularity;

public:
    pragma(inline, true)
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _remaining == 0;
    }

    pragma(inline, true)
    @property size_t length() const @safe pure nothrow @nogc
    {
        return _remaining;
    }

    pragma(inline, true)
    @property WayLocationView front() const @safe pure nothrow @nogc
    in (!empty)
    {
        return _front;
    }

    pragma(inline, true)
    void popFront() @safe nothrow @nogc
    in (!empty)
    {
        --_remaining;
        if (_remaining == 0)
        {
            _front = WayLocationView.init;
            return;
        }

        long latDelta;
        long lonDelta;
        bool hasLat;
        bool hasLon;
        PbfStatus ignored;
        if (!_lats.next(latDelta, hasLat, ignored) || !hasLat ||
            !_lons.next(lonDelta, hasLon, ignored) || !hasLon)
        {
            _remaining = 0;
            _front = WayLocationView.init;
            return;
        }

        long nextLat;
        long nextLon;
        long latNano;
        long lonNano;
        if (!checkedAdd(_lat, latDelta, nextLat) ||
            !checkedAdd(_lon, lonDelta, nextLon) ||
            !checkedMulAdd(
                _latOffset,
                cast(long)_granularity,
                nextLat,
                latNano) ||
            !checkedMulAdd(
                _lonOffset,
                cast(long)_granularity,
                nextLon,
                lonNano))
        {
            // Immutable bytes and coordinate arithmetic were fully preflighted.
            _remaining = 0;
            _front = WayLocationView.init;
            return;
        }

        _lat = nextLat;
        _lon = nextLon;
        _front = WayLocationView(latNano, lonNano);
    }
}

/** One validated regular Way with borrowed tags, refs, metadata, and provenance. */
struct WayView
{
    /// Signed OSM object ID as encoded by the Way `int64` field.
    long id;
    /// Borrowed ordered normal-element tags.
    TagRange tags;
    /// Borrowed ordered absolute OSM node IDs reconstructed from `refs` deltas.
    WayRefRange refs;
    /// Optional exact coordinates aligned one-to-one with `refs`. Empty when absent.
    WayLocationRange locations;
    /// Optional merged Info metadata.
    InfoView info;

    /// Complete original serialized Way payload, excluding group key/length.
    const(ubyte)[] raw;
    /// Byte offset of `raw` within `PrimitiveGroupLayout.raw`.
    size_t rawOffset;

    /// Semantic OSM element kind.
    @property ElementType type() const scope
        @safe pure nothrow @nogc
    {
        return ElementType.way;
    }
}

static assert(isElementView!WayView);

/** Summary of one completed regular-Way decode operation. */
struct WayDecodeSummary
{
    /// Number of Way messages delivered to the sink.
    size_t wayCount;
    /// Number of ordered tags exposed across all emitted ways.
    size_t tagCount;
    /// Number of ordered node references exposed across all emitted ways.
    size_t refCount;
    /// Number of optional per-reference locations exposed across all emitted ways.
    size_t locationCount;
}

private struct ParsedWay
{
    long id;
    InfoView info;
    TagValidationSummary tags;
    WayRefValidationSummary refs;
    WayLocationValidationSummary locations;
}

/**
 * Decode every regular Way in one validated PrimitiveGroup.
 *
 * The complete group is semantically preflighted before the first sink call.
 * Required Way IDs, merged Info metadata, normal-element tag references, and
 * every checked delta-coded node reference are therefore known valid before
 * any observable output occurs.
 *
 * `WayView.refs` contains absolute OSM node IDs. If `LocationsOnWays` data is
 * carried, `WayView.locations` exposes exact nanodegree coordinates in matching
 * order. The decoder intentionally performs no node lookup and no geometric
 * interpretation, keeping the PBF layer composable with higher geospatial layers
 * resolver and geometry libraries without forcing either dependency or
 * materialization here.
 */
bool decodeWays(Sink)(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    ref Sink sink,
    out WayDecodeSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    summary = WayDecodeSummary.init;

    if (group.wayOccurrences == 0)
    {
        status = PbfStatus.init;
        return true;
    }

    size_t preflightCount;
    size_t preflightTagCount;
    size_t preflightRefCount;
    size_t preflightLocationCount;
    auto preflight = WayMessageCursor(group.raw);

    while (true)
    {
        WayMessageRef wayRef;
        bool hasWay;
        if (!preflight.next(wayRef, hasWay, status))
            return false;
        if (!hasWay)
            break;

        ParsedWay parsed;
        if (!parseWay(block, wayRef, table, parsed, status))
            return false;

        ++preflightCount;
        preflightTagCount += parsed.tags.tagCount;
        preflightRefCount += parsed.refs.refCount;
        if (parsed.locations.hasLocations)
            preflightLocationCount += parsed.locations.latCount;
    }

    if (preflightCount != group.wayOccurrences)
    {
        status = PbfStatus.failure(PbfError.wayCountMismatch, 0, 3);
        return false;
    }

    auto ways = WayMessageCursor(group.raw);

    while (true)
    {
        WayMessageRef wayRef;
        bool hasWay;
        if (!ways.next(wayRef, hasWay, status))
            return false;
        if (!hasWay)
            break;

        WayView way;
        size_t wayTagCount;
        size_t wayRefCount;
        size_t wayLocationCount;
        if (!decodePrevalidatedWay(
            block,
            wayRef,
            table,
            way,
            wayTagCount,
            wayRefCount,
            wayLocationCount,
            status))
            return false;

        sink.put(way);
        ++summary.wayCount;
        summary.tagCount += wayTagCount;
        summary.refCount += wayRefCount;
        summary.locationCount += wayLocationCount;
    }

    if (summary.wayCount != preflightCount ||
        summary.tagCount != preflightTagCount ||
        summary.refCount != preflightRefCount ||
        summary.locationCount != preflightLocationCount)
    {
        status = PbfStatus.failure(PbfError.wayCountMismatch, 0, 3);
        return false;
    }

    status = PbfStatus.init;
    return true;
}

/**
 * Count one already-valid packed uint32 occurrence without repeating tag
 * StringTable semantics.
 *
 * This helper is used only by the emission pass after the complete immutable
 * PrimitiveGroup has passed `parseWay` preflight.
 */
pragma(inline, true)
private bool countPrevalidatedPackedUInt32(
    const(ubyte)[] packedBytes,
    size_t packedBase,
    uint fieldNumber,
    ref size_t count,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto packed = WireCursor(packedBytes);
    while (!packed.empty)
    {
        uint ignored;
        WireStatus wire;
        if (!readVarint32(packed, ignored, wire))
        {
            if (wire.fieldNumber == 0)
                wire.fieldNumber = fieldNumber;
            status = PbfStatus.fromTagWire(wire, packedBase);
            return false;
        }
        ++count;
    }

    status = PbfStatus.init;
    return true;
}

/**
 * Count one already-valid packed sint64 occurrence without repeating checked
 * delta accumulation or coordinate semantics.
 */
pragma(inline, true)
private bool countPrevalidatedPackedSInt64(
    const(ubyte)[] packedBytes,
    size_t packedBase,
    uint fieldNumber,
    ref size_t count,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto packed = WireCursor(packedBytes);
    while (!packed.empty)
    {
        long ignored;
        WireStatus wire;
        if (!readSVarint64(packed, ignored, wire))
        {
            if (wire.fieldNumber == 0)
                wire.fieldNumber = fieldNumber;
            status = PbfStatus.fromWayWire(wire, packedBase);
            return false;
        }
        ++count;
    }

    status = PbfStatus.init;
    return true;
}

/**
 * Reconstruct one Way for emission after complete group semantic preflight.
 *
 * Precondition: `wayRef.bytes` are the same immutable bytes previously accepted
 * by `parseWay` with the same PrimitiveBlock and StringTable. The first pass has
 * therefore already proved tag StringTable references, checked ref deltas,
 * LocationsOnWays alignment, checked coordinate accumulation/conversion, and
 * required-field semantics for every Way before any sink call.
 *
 * This second pass still re-decodes values needed by `WayView` and counts the
 * already-valid repeated columns so borrowed ranges can be rebuilt without
 * allocation. It deliberately does not repeat complete tag/ref/location
 * semantic validation.
 */
private bool decodePrevalidatedWay(
    ref const PrimitiveBlockLayout block,
    WayMessageRef wayRef,
    StringTableView table,
    out WayView way,
    out size_t tagCount,
    out size_t refCount,
    out size_t locationCount,
    out PbfStatus status)
    @safe nothrow @nogc
{
    way = WayView.init;
    tagCount = 0;
    refCount = 0;
    locationCount = 0;

    auto cursor = WireCursor(wayRef.bytes);
    bool hasId;
    long id;
    InfoView info;
    size_t latCount;
    size_t lonCount;

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
            return false;
        }

        if (field.number == 1 && field.wireType == WireType.varint)
        {
            ulong raw;
            if (!readVarint64(cursor, raw, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = field.number;
                status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                return false;
            }

            id = cast(long)raw;
            hasId = true;
            continue;
        }

        if (field.number == 2 && field.wireType == WireType.varint)
        {
            uint ignored;
            if (!readVarint32(cursor, ignored, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = field.number;
                status = PbfStatus.fromTagWire(wire, wayRef.rawOffset);
                return false;
            }

            ++tagCount;
            continue;
        }

        if (field.number == 2 && field.wireType == WireType.lengthDelimited)
        {
            const(ubyte)[] packedBytes;
            if (!readLengthDelimited(cursor, field.number, packedBytes, wire))
            {
                status = PbfStatus.fromTagWire(wire, wayRef.rawOffset);
                return false;
            }

            const packedBase =
                wayRef.rawOffset + cursor.offset - packedBytes.length;
            if (!countPrevalidatedPackedUInt32(
                packedBytes,
                packedBase,
                2,
                tagCount,
                status))
                return false;
            continue;
        }

        if ((field.number == 8 || field.number == 9 || field.number == 10) &&
            field.wireType == WireType.varint)
        {
            long ignored;
            if (!readSVarint64(cursor, ignored, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = field.number;
                status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                return false;
            }

            if (field.number == 8)
                ++refCount;
            else if (field.number == 9)
                ++latCount;
            else
                ++lonCount;
            continue;
        }

        if ((field.number == 8 || field.number == 9 || field.number == 10) &&
            field.wireType == WireType.lengthDelimited)
        {
            const(ubyte)[] packedBytes;
            if (!readLengthDelimited(cursor, field.number, packedBytes, wire))
            {
                status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                return false;
            }

            const packedBase =
                wayRef.rawOffset + cursor.offset - packedBytes.length;

            if (field.number == 8)
            {
                if (!countPrevalidatedPackedSInt64(
                    packedBytes,
                    packedBase,
                    8,
                    refCount,
                    status))
                    return false;
            }
            else if (field.number == 9)
            {
                if (!countPrevalidatedPackedSInt64(
                    packedBytes,
                    packedBase,
                    9,
                    latCount,
                    status))
                    return false;
            }
            else
            {
                if (!countPrevalidatedPackedSInt64(
                    packedBytes,
                    packedBase,
                    10,
                    lonCount,
                    status))
                    return false;
            }
            continue;
        }

        if (field.number == 4 && field.wireType == WireType.lengthDelimited)
        {
            const(ubyte)[] infoBytes;
            if (!readLengthDelimited(cursor, field.number, infoBytes, wire))
            {
                status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                return false;
            }

            const infoOffset =
                wayRef.rawOffset + cursor.offset - infoBytes.length;
            if (!mergeInfoMessage(
                infoBytes,
                infoOffset,
                info,
                status))
                return false;
            continue;
        }

        if (!skipFieldValue(cursor, field, wire))
        {
            status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
            return false;
        }
    }

    // These are defensive checks. The complete first pass already established
    // them for the same immutable bytes before this function can run.
    if (!hasId)
    {
        status = PbfStatus.failure(
            PbfError.missingWayId,
            wayRef.rawOffset,
            1);
        return false;
    }

    if ((latCount != 0 || lonCount != 0) &&
        (latCount != refCount || lonCount != refCount))
    {
        status = PbfStatus.failure(
            PbfError.wayLocationColumnLengthMismatch,
            wayRef.rawOffset,
            latCount != refCount ? 9 : 10);
        return false;
    }

    if (!finalizeInfo(block, table, info, status))
        return false;

    TagValidationSummary tagSummary;
    tagSummary.keyCount = tagCount;
    tagSummary.valueCount = tagCount;

    TagRange tags;
    if (!buildTagRange(
        wayRef.bytes,
        wayRef.rawOffset,
        table,
        tagSummary,
        tags,
        status))
        return false;

    WayRefValidationSummary refSummary;
    refSummary.refCount = refCount;

    WayRefRange refs;
    if (!buildWayRefRange(
        wayRef.bytes,
        wayRef.rawOffset,
        refSummary,
        refs,
        status))
        return false;

    WayLocationValidationSummary locationSummary;
    locationSummary.latCount = latCount;
    locationSummary.lonCount = lonCount;

    WayLocationRange locations;
    if (!buildWayLocationRange(
        block,
        wayRef.bytes,
        wayRef.rawOffset,
        locationSummary,
        locations,
        status))
        return false;

    locationCount = latCount;
    way = WayView(
        id,
        tags,
        refs,
        locations,
        info,
        wayRef.bytes,
        wayRef.rawOffset);

    status = PbfStatus.init;
    return true;
}

private bool parseWay(
    ref const PrimitiveBlockLayout block,
    WayMessageRef wayRef,
    StringTableView table,
    out ParsedWay parsed,
    out PbfStatus status)
    @safe nothrow @nogc
{
    parsed = ParsedWay.init;
    auto cursor = WireCursor(wayRef.bytes);
    bool hasId;

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
            return false;
        }

        if (field.number == 1 && field.wireType == WireType.varint)
        {
            ulong raw;
            if (!readVarint64(cursor, raw, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = field.number;
                status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                return false;
            }

            // Way.id is protobuf int64, not sint64. The cast preserves the
            // exact two's-complement value represented by the wire varint.
            parsed.id = cast(long)raw;
            hasId = true;
            continue;
        }

        if (field.number == 4 && field.wireType == WireType.lengthDelimited)
        {
            const(ubyte)[] infoBytes;
            if (!readLengthDelimited(cursor, field.number, infoBytes, wire))
            {
                status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                return false;
            }

            const infoOffset =
                wayRef.rawOffset + cursor.offset - infoBytes.length;
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
            status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
            return false;
        }
    }

    if (!hasId)
    {
        status = PbfStatus.failure(
            PbfError.missingWayId,
            wayRef.rawOffset,
            1);
        return false;
    }

    if (!finalizeInfo(block, table, parsed.info, status))
        return false;

    if (!validateTags(
        wayRef.bytes,
        wayRef.rawOffset,
        table,
        parsed.tags,
        status))
        return false;

    if (!validateWayRefs(
        wayRef.bytes,
        wayRef.rawOffset,
        parsed.refs,
        status))
        return false;

    if (!validateWayLocations(
        block,
        wayRef.bytes,
        wayRef.rawOffset,
        parsed.refs.refCount,
        parsed.locations,
        status))
        return false;

    status = PbfStatus.init;
    return true;
}

/** Validate and checked-accumulate the complete logical Way `refs` column. */
bool validateWayRefs(
    const(ubyte)[] input,
    size_t baseOffset,
    out WayRefValidationSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    summary = WayRefValidationSummary.init;
    auto refs = SInt64FieldCursor(input, baseOffset, 8);
    long current;

    while (true)
    {
        long delta;
        bool hasValue;
        if (!refs.next(delta, hasValue, status))
            return false;
        if (!hasValue)
            break;

        long next;
        if (!checkedAdd(current, delta, next))
        {
            status = PbfStatus.failure(
                PbfError.wayRefOverflow,
                refs.lastValueOffset,
                8);
            return false;
        }

        current = next;
        ++summary.refCount;
    }

    summary.finalRef = current;
    status = PbfStatus.init;
    return true;
}

/** Build a borrowed absolute-reference range from already validated Way bytes. */
bool buildWayRefRange(
    const(ubyte)[] input,
    size_t baseOffset,
    WayRefValidationSummary summary,
    out WayRefRange range,
    out PbfStatus status)
    @safe nothrow @nogc
{
    range = WayRefRange.init;
    range._deltas = SInt64FieldCursor(input, baseOffset, 8);
    range._remaining = summary.refCount;

    if (range._remaining == 0)
    {
        status = PbfStatus.init;
        return true;
    }

    long delta;
    bool hasValue;
    if (!range._deltas.next(delta, hasValue, status) || !hasValue)
    {
        if (status.ok)
            status = PbfStatus.failure(PbfError.wayCountMismatch, baseOffset, 8);
        range = WayRefRange.init;
        return false;
    }

    long first;
    if (!checkedAdd(0L, delta, first))
    {
        status = PbfStatus.failure(
            PbfError.wayRefOverflow,
            range._deltas.lastValueOffset,
            8);
        range = WayRefRange.init;
        return false;
    }

    range._current = first;
    range._front = first;
    status = PbfStatus.init;
    return true;
}

/**
 * Validate optional `LocationsOnWays` coordinate columns.
 *
 * If either latitude or longitude values are present, both logical columns must
 * have exactly `expectedRefCount` entries. Delta accumulation and exact
 * nanodegree conversion are checked before any Way is emitted. Header-level
 * advertisement of the `LocationsOnWays` optional feature is validated by the
 * file/header pipeline rather than this message-local decoder.
 */
bool validateWayLocations(
    ref const PrimitiveBlockLayout block,
    const(ubyte)[] input,
    size_t baseOffset,
    size_t expectedRefCount,
    out WayLocationValidationSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    summary = WayLocationValidationSummary.init;

    auto lats = SInt64FieldCursor(input, baseOffset, 9);
    long lat;
    while (true)
    {
        long delta;
        bool hasValue;
        if (!lats.next(delta, hasValue, status))
            return false;
        if (!hasValue)
            break;

        long next;
        if (!checkedAdd(lat, delta, next))
        {
            status = PbfStatus.failure(
                PbfError.wayCoordinateOverflow,
                lats.lastValueOffset,
                9);
            return false;
        }

        long ignoredNano;
        if (!checkedMulAdd(
            block.latOffset,
            cast(long)block.granularity,
            next,
            ignoredNano))
        {
            status = PbfStatus.failure(
                PbfError.wayCoordinateOverflow,
                lats.lastValueOffset,
                9);
            return false;
        }

        lat = next;
        ++summary.latCount;
    }

    auto lons = SInt64FieldCursor(input, baseOffset, 10);
    long lon;
    while (true)
    {
        long delta;
        bool hasValue;
        if (!lons.next(delta, hasValue, status))
            return false;
        if (!hasValue)
            break;

        long next;
        if (!checkedAdd(lon, delta, next))
        {
            status = PbfStatus.failure(
                PbfError.wayCoordinateOverflow,
                lons.lastValueOffset,
                10);
            return false;
        }

        long ignoredNano;
        if (!checkedMulAdd(
            block.lonOffset,
            cast(long)block.granularity,
            next,
            ignoredNano))
        {
            status = PbfStatus.failure(
                PbfError.wayCoordinateOverflow,
                lons.lastValueOffset,
                10);
            return false;
        }

        lon = next;
        ++summary.lonCount;
    }

    summary.finalLat = lat;
    summary.finalLon = lon;

    if (summary.hasLocations &&
        (summary.latCount != expectedRefCount ||
         summary.lonCount != expectedRefCount))
    {
        status = PbfStatus.failure(
            PbfError.wayLocationColumnLengthMismatch,
            baseOffset,
            summary.latCount != expectedRefCount ? 9 : 10);
        return false;
    }

    status = PbfStatus.init;
    return true;
}

/** Build the borrowed optional location range after successful preflight. */
bool buildWayLocationRange(
    ref const PrimitiveBlockLayout block,
    const(ubyte)[] input,
    size_t baseOffset,
    WayLocationValidationSummary summary,
    out WayLocationRange range,
    out PbfStatus status)
    @safe nothrow @nogc
{
    range = WayLocationRange.init;
    if (!summary.hasLocations)
    {
        status = PbfStatus.init;
        return true;
    }

    range._lats = SInt64FieldCursor(input, baseOffset, 9);
    range._lons = SInt64FieldCursor(input, baseOffset, 10);
    range._remaining = summary.latCount;
    range._latOffset = block.latOffset;
    range._lonOffset = block.lonOffset;
    range._granularity = block.granularity;

    long latDelta;
    long lonDelta;
    bool hasLat;
    bool hasLon;
    if (!range._lats.next(latDelta, hasLat, status) || !hasLat ||
        !range._lons.next(lonDelta, hasLon, status) || !hasLon)
    {
        if (status.ok)
            status = PbfStatus.failure(
                PbfError.wayLocationColumnLengthMismatch,
                baseOffset,
                !hasLat ? 9 : 10);
        range = WayLocationRange.init;
        return false;
    }

    long lat;
    long lon;
    long latNano;
    long lonNano;
    if (!checkedAdd(0L, latDelta, lat) ||
        !checkedAdd(0L, lonDelta, lon) ||
        !checkedMulAdd(
            block.latOffset,
            cast(long)block.granularity,
            lat,
            latNano) ||
        !checkedMulAdd(
            block.lonOffset,
            cast(long)block.granularity,
            lon,
            lonNano))
    {
        status = PbfStatus.failure(
            PbfError.wayCoordinateOverflow,
            baseOffset,
            9);
        range = WayLocationRange.init;
        return false;
    }

    range._lat = lat;
    range._lon = lon;
    range._front = WayLocationView(latNano, lonNano);
    status = PbfStatus.init;
    return true;
}

private struct WayMessageRef
{
    const(ubyte)[] bytes;
    size_t rawOffset;
}

private struct WayMessageCursor
{
private:
    WireCursor _group;

public:
    this(const(ubyte)[] group) @safe nothrow @nogc
    {
        _group = WireCursor(group);
    }

    bool next(
        out WayMessageRef way,
        out bool hasWay,
        out PbfStatus status)
        @safe nothrow @nogc
    {
        way = WayMessageRef.init;
        hasWay = false;

        while (!_group.empty)
        {
            FieldHeader field;
            WireStatus wire;
            if (!readFieldHeader(_group, field, wire))
            {
                status = PbfStatus.fromPrimitiveGroupWire(wire);
                return false;
            }

            if (field.number == 3 && field.wireType == WireType.lengthDelimited)
            {
                const(ubyte)[] payload;
                if (!readLengthDelimited(_group, field.number, payload, wire))
                {
                    status = PbfStatus.fromPrimitiveGroupWire(wire);
                    return false;
                }

                way = WayMessageRef(
                    payload,
                    _group.offset - payload.length);
                hasWay = true;
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

/** Logical cursor over one repeated sint64 field in a protobuf message. */
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

    pragma(inline, true)
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
                    status = PbfStatus.fromWayWire(wire, _packedBase);
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
                    status = PbfStatus.fromWayWire(wire, _baseOffset);
                    return false;
                }

                if (field.number == _fieldNumber &&
                    field.wireType == WireType.varint)
                {
                    _lastValueOffset = _baseOffset + _message.offset;
                    if (!readSVarint64(_message, value, wire))
                    {
                        if (wire.fieldNumber == 0)
                            wire.fieldNumber = field.number;
                        status = PbfStatus.fromWayWire(wire, _baseOffset);
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
                        status = PbfStatus.fromWayWire(wire, _baseOffset);
                        return false;
                    }

                    _packedBase =
                        _baseOffset + _message.offset - packed.length;
                    _packed = WireCursor(packed);

                    if (!_packed.empty)
                        break;

                    // Empty packed occurrences are legal and contribute no refs.
                    continue;
                }

                if (!skipFieldValue(_message, field, wire))
                {
                    status = PbfStatus.fromWayWire(wire, _baseOffset);
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

    // Way id=100, tags (1->2, 3->4), Info(version=7,timestamp=10,user=5,
    // visible), refs absolute [10, 12, 11] encoded as deltas [10, 2, -1].
    const(ubyte)[] groupBytes = [
        0x1a, 0x19,
        0x08, 0x64,
        0x12, 0x02, 0x01, 0x03,
        0x1a, 0x02, 0x02, 0x04,
        0x22, 0x08,
        0x08, 0x07,
        0x10, 0x0a,
        0x28, 0x05,
        0x30, 0x01,
        0x42, 0x03, 0x14, 0x04, 0x01,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));
    assert(group.wayOccurrences == 1);

    PrimitiveBlockLayout block;
    block.dateGranularity = 1000;

    const(ubyte)[] strings = [0, 'k', 'v', 'n', 'x', 'u'];
    StringRef[6] stringRefs = [
        StringRef(0, 0),
        StringRef(1, 1),
        StringRef(2, 1),
        StringRef(3, 1),
        StringRef(4, 1),
        StringRef(5, 1),
    ];
    StringTableView table = StringTableView(strings, stringRefs[]);

    struct Sink
    {
        WayView way;
        size_t used;

        void put(WayView value) @safe nothrow @nogc
        {
            way = value;
            ++used;
        }
    }

    Sink sink;
    WayDecodeSummary summary;
    assert(decodeWays(block, group, table, sink, summary, status));
    assert(status.ok);
    assert(summary.wayCount == 1);
    assert(summary.tagCount == 2);
    assert(summary.refCount == 3);
    assert(summary.locationCount == 0);
    assert(sink.used == 1);

    assert(sink.way.id == 100);
    assert(sink.way.raw.length == 25);
    assert(sink.way.info.hasVersion && sink.way.info.version_ == 7);
    assert(sink.way.info.hasTimestamp);
    assert(sink.way.info.timestampMillis == 10_000);
    assert(sink.way.info.hasUser && sink.way.info.userSid == 5);
    assert(sink.way.info.hasVisible && sink.way.info.visible);

    auto tags = sink.way.tags;
    assert(tags.length == 2);
    assert(tags.front.keySid == 1 && tags.front.valueSid == 2);
    tags.popFront();
    assert(tags.front.keySid == 3 && tags.front.valueSid == 4);
    tags.popFront();
    assert(tags.empty);

    auto refs = sink.way.refs;
    assert(refs.length == 3);
    assert(refs.front == 10);
    refs.popFront();
    assert(refs.front == 12);
    refs.popFront();
    assert(refs.front == 11);
    refs.popFront();
    assert(refs.empty);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Duplicate id is last-one-wins. refs are interleaved unpacked and packed:
    // deltas +5, +2, -1 => absolute [5, 7, 6].
    const(ubyte)[] groupBytes = [
        0x1a, 0x0a,
        0x08, 0x01,
        0x40, 0x0a,
        0x08, 0x07,
        0x42, 0x02, 0x04, 0x01,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0];
    StringRef[1] stringRefs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, stringRefs[]);

    struct Sink
    {
        WayView way;
        size_t used;
        void put(WayView value) @safe nothrow @nogc
        {
            way = value;
            ++used;
        }
    }

    Sink sink;
    WayDecodeSummary summary;
    assert(decodeWays(block, group, table, sink, summary, status));
    assert(sink.used == 1 && sink.way.id == 7);

    auto refs = sink.way.refs;
    assert(refs.front == 5);
    refs.popFront();
    assert(refs.front == 7);
    refs.popFront();
    assert(refs.front == 6);
    refs.popFront();
    assert(refs.empty);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // LocationsOnWays: refs [10,12], lat-grid [100,101], lon-grid [-50,-48].
    const(ubyte)[] groupBytes = [
        0x1a, 0x0f,
        0x08, 0x01,
        0x42, 0x02, 0x14, 0x04,
        0x4a, 0x03, 0xc8, 0x01, 0x02,
        0x52, 0x02, 0x63, 0x04,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    block.granularity = 100;
    block.latOffset = 1000;
    block.lonOffset = -1000;

    const(ubyte)[] strings = [0];
    StringRef[1] stringRefs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, stringRefs[]);

    struct Sink
    {
        WayView way;
        void put(WayView value) @safe nothrow @nogc
        {
            way = value;
        }
    }

    Sink sink;
    WayDecodeSummary summary;
    assert(decodeWays(block, group, table, sink, summary, status));
    assert(summary.refCount == 2 && summary.locationCount == 2);

    auto locations = sink.way.locations;
    assert(locations.length == 2);
    assert(locations.front.latNano == 11_000);
    assert(locations.front.lonNano == -6_000);
    locations.popFront();
    assert(locations.front.latNano == 11_100);
    assert(locations.front.lonNano == -5_800);
    locations.popFront();
    assert(locations.empty);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // LocationsOnWays columns must align one-to-one with refs.
    const(ubyte)[] groupBytes = [
        0x1a, 0x0d,
        0x08, 0x01,
        0x42, 0x02, 0x02, 0x02,
        0x4a, 0x01, 0x02,
        0x52, 0x02, 0x02, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    block.granularity = 100;
    const(ubyte)[] strings = [0];
    StringRef[1] stringRefs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, stringRefs[]);

    struct Sink
    {
        size_t used;
        void put(WayView) @safe nothrow @nogc
        {
            ++used;
        }
    }

    Sink sink;
    WayDecodeSummary summary;
    assert(!decodeWays(block, group, table, sink, summary, status));
    assert(status.error == PbfError.wayLocationColumnLengthMismatch);
    assert(sink.used == 0);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // A late overflow in the second Way must fail the complete preflight before
    // the first valid Way becomes observable.
    const(ubyte)[] groupBytes = [
        0x1a, 0x05,
        0x08, 0x01,
        0x42, 0x01, 0x02,

        0x1a, 0x0f,
        0x08, 0x02,
        0x42, 0x0b,
        0xfe, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
        0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));
    assert(group.wayOccurrences == 2);

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0];
    StringRef[1] stringRefs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, stringRefs[]);

    struct Sink
    {
        size_t used;
        void put(WayView) @safe nothrow @nogc
        {
            ++used;
        }
    }

    Sink sink;
    WayDecodeSummary summary;
    assert(!decodeWays(block, group, table, sink, summary, status));
    assert(status.error == PbfError.wayRefOverflow);
    assert(status.fieldNumber == 8);
    assert(sink.used == 0);
    assert(summary.wayCount == 0);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    const(ubyte)[] groupBytes = [0x1a, 0x00];
    PrimitiveGroupLayout group;
    PbfStatus status;
    assert(decodePrimitiveGroupLayout(groupBytes, group, status));

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0];
    StringRef[1] stringRefs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, stringRefs[]);

    struct Sink
    {
        size_t used;
        void put(WayView) @safe nothrow @nogc
        {
            ++used;
        }
    }

    Sink sink;
    WayDecodeSummary summary;
    assert(!decodeWays(block, group, table, sink, summary, status));
    assert(status.error == PbfError.missingWayId);
    assert(status.fieldNumber == 1);
    assert(sink.used == 0);
}
