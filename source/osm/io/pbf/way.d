/**
 * Streaming decode of regular OSMPBF `Way` messages.
 *
 * A Way remains an OSM topological object at this layer: it exposes its signed
 * OSM ID, ordered tags, optional Info metadata, and the ordered absolute node
 * IDs reconstructed from the delta-coded `refs` column. The semantic
 * `nodes` range combines those references with optional `LocationsOnWays`
 * coordinates without exposing the parallel-column representation to ordinary
 * consumers. The Way is deliberately not interpreted as a line or
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
import osm.view.location : LocationView;
import osm.view.metadata : MetadataView;
import osm.view.way_node : WayNodeView;
import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.info :
    InfoView,
    finalizeInfo,
    mergeInfoMessage;
import osm.io.pbf.primitive_block : PrimitiveBlockLayout;
import osm.io.pbf.primitive_group : PrimitiveGroupLayout;
import osm.io.pbf.string_table : StringRef, StringTableView;
import osm.io.pbf.tags :
    TagRange,
    TagValidationSummary,
    buildPrevalidatedPackedTagRange,
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
    readLengthDelimitedCursor,
    skipFieldValue;
import osm.wire.varint :
    readSVarint64,
    readSVarint64FailureOnly,
    readVarint32,
    readVarint64;

/** Validation summary for one Way's delta-coded node-reference column. */
package(osm)
struct WayRefValidationSummary
{
    /// Number of logical refs after concatenating packed/unpacked occurrences.
    size_t refCount;
    /// Final absolute node ID after checked accumulation of every delta.
    long finalRef;
}

/** Validation summary for optional `LocationsOnWays` latitude/longitude columns. */
package(osm)
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
    @property bool empty() const scope @safe pure nothrow @nogc
    {
        return _remaining == 0;
    }

    /** Returns the number of node references not yet consumed. */
    pragma(inline, true)
    @property size_t length() const scope @safe pure nothrow @nogc
    {
        return _remaining;
    }

    /** Return the current absolute OSM node ID. */
    pragma(inline, true)
    @property long front() const scope @safe pure nothrow @nogc
    in (!empty)
    {
        return _front;
    }

    /** Advance to the next already validated absolute node ID. */
    pragma(inline, true)
    void popFront() scope @safe nothrow @nogc
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
            // The backing bytes were completely preflighted and must remain unchanged.
            _remaining = 0;
            _front = 0;
            return;
        }

        _current = next;
        _front = next;
    }
}

/**
 * Compatibility name for a semantic location aligned with one Way reference.
 *
 * New consumer code should use LocationView. The alias keeps the evolving
 * pre-1.0 direct-PBF surface source-compatible while way locations adopt the
 * same coordinate vocabulary as nodes.
 */
alias WayLocationView = LocationView;

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
    @property bool empty() const scope @safe pure nothrow @nogc
    {
        return _remaining == 0;
    }

    pragma(inline, true)
    @property size_t length() const scope @safe pure nothrow @nogc
    {
        return _remaining;
    }

    pragma(inline, true)
    @property WayLocationView front() const scope @safe pure nothrow @nogc
    in (!empty)
    {
        return _front;
    }

    pragma(inline, true)
    void popFront() scope @safe nothrow @nogc
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
            // The backing bytes and coordinate arithmetic were fully preflighted.
            _remaining = 0;
            _front = WayLocationView.init;
            return;
        }

        _lat = nextLat;
        _lon = nextLon;
        _front = WayLocationView(latNano, lonNano);
    }
}

/**
 * Borrowed semantic range over one Way's ordered node references.
 *
 * The PBF decoder may retain separate reference and optional location columns
 * internally. This range projects them into one OSM-facing sequence without
 * allocation, node lookup, or geometry construction.
 */
struct WayNodeRange
{
private:
    WayRefRange _refs;
    WayLocationRange _locations;

package(osm):
    this(
        return scope WayRefRange refs,
        return scope WayLocationRange locations)
        @safe pure nothrow @nogc
    {
        assert(locations.empty || locations.length == refs.length);
        _refs = refs;
        _locations = locations;
    }

public:
    /** Returns true when no Way node reference remains. */
    pragma(inline, true)
    @property bool empty() const scope @safe pure nothrow @nogc
    {
        return _refs.empty;
    }

    /** Returns the number of Way node references not yet consumed. */
    pragma(inline, true)
    @property size_t length() const scope @safe pure nothrow @nogc
    {
        return _refs.length;
    }

    /** Return the current semantic Way node reference. */
    pragma(inline, true)
    @property WayNodeView front() const scope @safe pure nothrow @nogc
    in (!empty)
    {
        if (_locations.empty)
            return WayNodeView(_refs.front);

        return WayNodeView(_refs.front, _locations.front);
    }

    /** Advance to the next already validated Way node reference. */
    pragma(inline, true)
    void popFront() scope @safe nothrow @nogc
    in (!empty)
    {
        _refs.popFront();
        if (!_locations.empty)
            _locations.popFront();
    }
}

/** One validated regular Way with borrowed tags, refs, metadata, and provenance. */
struct WayView
{
public:
    /// Signed OSM object ID as encoded by the Way `int64` field.
    long id;
    /// Borrowed ordered normal-element tags.
    TagRange tags;

package(osm):
    /// Borrowed ordered absolute OSM node IDs reconstructed from `refs` deltas.
    WayRefRange refs;
    /// Optional exact coordinates aligned one-to-one with `refs`. Empty when absent.
    WayLocationRange locations;
    /// Optional merged Info metadata.
    InfoView info;

public:
    /**
     * Ordered semantic Way node references with optional aligned locations.
     *
     * The returned range is lazy and allocation-free. It performs no node
     * lookup and no geometry construction.
     */
    pragma(inline, true)
    @property WayNodeRange nodes() return scope
        @safe pure nothrow @nogc
    {
        return WayNodeRange(refs, locations);
    }

    /** Format-independent OSM metadata without PBF encoding vocabulary. */
    pragma(inline, true)
    @property MetadataView metadata() const return scope
        @safe pure nothrow @nogc
    {
        return MetadataView(
            info.hasVersion, info.version_,
            info.hasTimestamp, info.timestampMillis,
            info.hasChangeset, info.changeset,
            info.hasUid, info.uid,
            info.hasUser, info.user,
            info.hasVisible, info.visible);
    }

package(osm):
    /// Complete original serialized Way payload, excluding group key/length.
    const(ubyte)[] raw;
    /// Byte offset of `raw` within `PrimitiveGroupLayout.raw`.
    size_t rawOffset;

public:
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
 * Compact copy of finalized regular-Way Info state kept in caller-owned
 * preflight workspace.
 *
 * The borrowed username slice is represented by its existing StringRef so a
 * per-Way plan does not retain a full D slice. Presence remains explicit.
 */
package(osm)
struct WayCompactInfo
{
    long timestampValue;
    long timestampMillis;
    long changeset;
    StringRef user;
    int version_;
    int uid;
    uint userSid;
    ubyte flags;
}

private enum ubyte wayInfoHasVersion   = 1u << 0;
private enum ubyte wayInfoHasTimestamp = 1u << 1;
private enum ubyte wayInfoHasChangeset = 1u << 2;
private enum ubyte wayInfoHasUid       = 1u << 3;
private enum ubyte wayInfoHasUser      = 1u << 4;
private enum ubyte wayInfoHasVisible   = 1u << 5;
private enum ubyte wayInfoVisibleValue = 1u << 6;

/**
 * Compact location of one canonical packed repeated-field payload.
 *
 * Offsets are relative to PrimitiveGroupLayout.raw.
 */
package(osm)
struct WayPackedSpan
{
    uint offset;
    uint length;
}

/**
 * Caller-owned per-Way semantic/emission plan.
 *
 * Every entry describes one fully preflighted Way. `canonicalPacked` means
 * keys, vals, refs, lats and lons are each absent or represented by exactly
 * one packed occurrence, allowing emission ranges to start directly from the
 * saved payload spans. Otherwise the existing generic range builders remain
 * authoritative for the same validated raw Way bytes.
 */
package(osm)
struct WayDecodePlan
{
    long id;
    WayCompactInfo info;
    uint rawOffset;
    uint rawLength;
    uint tagCount;
    uint refCount;
    uint locationCount;
    WayPackedSpan keys;
    WayPackedSpan vals;
    WayPackedSpan refs;
    WayPackedSpan lats;
    WayPackedSpan lons;
    bool canonicalPacked;
}

static if (size_t.sizeof == 8)
{
    static assert(WayCompactInfo.sizeof == 48);
    static assert(WayPackedSpan.sizeof == 8);
    static assert(WayDecodePlan.sizeof == 120);
}

pragma(inline, true)
private WayCompactInfo compactInfoFromView(
    ref const InfoView info,
    StringTableView table)
    @safe pure nothrow @nogc
{
    WayCompactInfo compact;
    compact.timestampValue = info.timestampValue;
    compact.timestampMillis = info.timestampMillis;
    compact.changeset = info.changeset;
    compact.version_ = info.version_;
    compact.uid = info.uid;
    compact.userSid = info.userSid;

    if (info.hasUser)
    {
        const index = cast(size_t)info.userSid;
        if (index < table.entries.length)
            compact.user = table.entries[index];
    }

    if (info.hasVersion)
        compact.flags |= wayInfoHasVersion;
    if (info.hasTimestamp)
        compact.flags |= wayInfoHasTimestamp;
    if (info.hasChangeset)
        compact.flags |= wayInfoHasChangeset;
    if (info.hasUid)
        compact.flags |= wayInfoHasUid;
    if (info.hasUser)
        compact.flags |= wayInfoHasUser;
    if (info.hasVisible)
        compact.flags |= wayInfoHasVisible;
    if (info.visible)
        compact.flags |= wayInfoVisibleValue;

    return compact;
}

pragma(inline, true)
private bool expandCompactInfo(
    WayCompactInfo compact,
    StringTableView table,
    out InfoView info)
    @safe nothrow @nogc
{
    info = InfoView.init;

    if (compact.flags & wayInfoHasVersion)
    {
        info.hasVersion = true;
        info.version_ = compact.version_;
    }

    if (compact.flags & wayInfoHasTimestamp)
    {
        info.hasTimestamp = true;
        info.timestampValue = compact.timestampValue;
        info.timestampMillis = compact.timestampMillis;
    }

    if (compact.flags & wayInfoHasChangeset)
    {
        info.hasChangeset = true;
        info.changeset = compact.changeset;
    }

    if (compact.flags & wayInfoHasUid)
    {
        info.hasUid = true;
        info.uid = compact.uid;
    }

    if (compact.flags & wayInfoHasUser)
    {
        const start = cast(size_t)compact.user.offset;
        const length = cast(size_t)compact.user.length;

        if (start > table.rawBlock.length ||
            length > table.rawBlock.length - start)
            return false;

        info.hasUser = true;
        info.userSid = compact.userSid;
        info.user = table.rawBlock[start .. start + length];
    }

    if (compact.flags & wayInfoHasVisible)
    {
        info.hasVisible = true;
        info.visible = (compact.flags & wayInfoVisibleValue) != 0;
    }

    return true;
}

/**
 * Result of attempting the narrow canonical packed-Way preflight.
 *
 * `fallback` is not an input error. It means the Way uses a legal protobuf
 * representation that must be handled by the existing generic parser.
 */
private enum CanonicalWayPlanResult : ubyte
{
    success,
    fallback,
    error,
}

pragma(inline, true)
private bool validateCanonicalPackedTags(
    const(ubyte)[] keyPayload,
    size_t keyPayloadBase,
    const(ubyte)[] valuePayload,
    size_t valuePayloadBase,
    StringTableView table,
    out TagValidationSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    summary = TagValidationSummary.init;
    auto keys = WireCursor(keyPayload);
    auto vals = WireCursor(valuePayload);

    while (true)
    {
        const hasKey = !keys.empty;
        const hasValue = !vals.empty;

        uint keySid;
        uint valueSid;
        const keyOffset = keyPayloadBase + keys.offset;
        const valueOffset = valuePayloadBase + vals.offset;

        if (hasKey)
        {
            WireStatus wire;
            if (!readVarint32(keys, keySid, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = 2;
                status = PbfStatus.fromTagWire(wire, keyPayloadBase);
                return false;
            }
            ++summary.keyCount;
        }

        if (hasValue)
        {
            WireStatus wire;
            if (!readVarint32(vals, valueSid, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = 3;
                status = PbfStatus.fromTagWire(wire, valuePayloadBase);
                return false;
            }
            ++summary.valueCount;
        }

        if (hasKey != hasValue)
        {
            status = PbfStatus.failure(
                PbfError.tagColumnLengthMismatch,
                hasKey ? keyOffset : valueOffset,
                hasKey ? 2 : 3);
            return false;
        }

        if (!hasKey)
            break;

        if (keySid == 0)
        {
            status = PbfStatus.failure(
                PbfError.invalidTagStringId,
                keyOffset,
                2);
            return false;
        }

        if (cast(size_t)keySid >= table.length)
        {
            status = PbfStatus.failure(
                PbfError.tagStringIdOutOfRange,
                keyOffset,
                2);
            return false;
        }

        if (valueSid == 0)
        {
            status = PbfStatus.failure(
                PbfError.invalidTagStringId,
                valueOffset,
                3);
            return false;
        }

        if (cast(size_t)valueSid >= table.length)
        {
            status = PbfStatus.failure(
                PbfError.tagStringIdOutOfRange,
                valueOffset,
                3);
            return false;
        }
    }

    status = PbfStatus.init;
    return true;
}

pragma(inline, true)
private bool validateCanonicalPackedRefs(
    const(ubyte)[] payload,
    size_t payloadBase,
    ref WayRefValidationSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto packed = WireCursor(payload);
    long current;

    while (!packed.empty)
    {
        const valueOffset = payloadBase + packed.offset;

        long delta;
        WireStatus wire;
        if (!readSVarint64(packed, delta, wire))
        {
            if (wire.fieldNumber == 0)
                wire.fieldNumber = 8;
            status = PbfStatus.fromWayWire(wire, payloadBase);
            return false;
        }

        long next;
        if (!checkedAdd(current, delta, next))
        {
            status = PbfStatus.failure(
                PbfError.wayRefOverflow,
                valueOffset,
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

pragma(inline, true)
private bool validateCanonicalPackedCoordinate(
    const(ubyte)[] payload,
    size_t payloadBase,
    uint fieldNumber,
    long coordinateOffset,
    uint granularity,
    ref size_t count,
    out long finalValue,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto packed = WireCursor(payload);
    long current;

    while (!packed.empty)
    {
        const valueOffset = payloadBase + packed.offset;

        long delta;
        WireStatus wire;
        if (!readSVarint64(packed, delta, wire))
        {
            if (wire.fieldNumber == 0)
                wire.fieldNumber = fieldNumber;
            status = PbfStatus.fromWayWire(wire, payloadBase);
            return false;
        }

        long next;
        if (!checkedAdd(current, delta, next))
        {
            status = PbfStatus.failure(
                PbfError.wayCoordinateOverflow,
                valueOffset,
                fieldNumber);
            return false;
        }

        long ignoredNano;
        if (!checkedMulAdd(
            coordinateOffset,
            cast(long)granularity,
            next,
            ignoredNano))
        {
            status = PbfStatus.failure(
                PbfError.wayCoordinateOverflow,
                valueOffset,
                fieldNumber);
            return false;
        }

        current = next;
        ++count;
    }

    finalValue = current;
    status = PbfStatus.init;
    return true;
}

/**
 * Attempt one semantic field scan for the common canonical Way representation.
 *
 * Repeated Way columns must each be absent or represented by exactly one
 * length-delimited packed occurrence. Any other otherwise-legal representation
 * returns `fallback`; malformed wire data and semantic failures return `error`.
 */
private CanonicalWayPlanResult tryBuildCanonicalWayDecodePlan(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    WayMessageRef wayRef,
    StringTableView table,
    out WayDecodePlan plan,
    out PbfStatus status)
    @safe nothrow @nogc
{
    plan = WayDecodePlan.init;

    ParsedWay parsed;
    WayPackedSpan keys;
    WayPackedSpan vals;
    WayPackedSpan refs;
    WayPackedSpan lats;
    WayPackedSpan lons;

    const(ubyte)[] keyPayload;
    const(ubyte)[] valuePayload;
    const(ubyte)[] refPayload;
    const(ubyte)[] latPayload;
    const(ubyte)[] lonPayload;

    size_t keyPayloadBase;
    size_t valuePayloadBase;
    size_t refPayloadBase;
    size_t latPayloadBase;
    size_t lonPayloadBase;

    bool hasId;
    bool seenKeys;
    bool seenVals;
    bool seenRefs;
    bool seenLats;
    bool seenLons;

    auto cursor = WireCursor(wayRef.bytes);

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
            return CanonicalWayPlanResult.error;
        }

        if (field.number == 1 && field.wireType == WireType.varint)
        {
            ulong raw;
            if (!readVarint64(cursor, raw, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = field.number;
                status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                return CanonicalWayPlanResult.error;
            }

            // Singular protobuf scalar: later occurrences win.
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
                status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
                return CanonicalWayPlanResult.error;
            }

            const infoOffset =
                wayRef.rawOffset + cursor.offset - infoBytes.length;

            if (!mergeInfoMessage(
                infoBytes,
                infoOffset,
                parsed.info,
                status))
            {
                return CanonicalWayPlanResult.error;
            }

            continue;
        }

        if (field.number == 2 ||
            field.number == 3 ||
            field.number == 8 ||
            field.number == 9 ||
            field.number == 10)
        {
            if (field.wireType != WireType.lengthDelimited)
            {
                status = PbfStatus.init;
                return CanonicalWayPlanResult.fallback;
            }

            const(ubyte)[] payload;
            if (!readLengthDelimited(
                cursor,
                field.number,
                payload,
                wire))
            {
                if (field.number == 2 || field.number == 3)
                    status = PbfStatus.fromTagWire(
                        wire,
                        wayRef.rawOffset);
                else
                    status = PbfStatus.fromWayWire(
                        wire,
                        wayRef.rawOffset);
                return CanonicalWayPlanResult.error;
            }

            const payloadBase =
                wayRef.rawOffset + cursor.offset - payload.length;

            if (payloadBase > uint.max ||
                payload.length > uint.max)
            {
                status = PbfStatus.init;
                return CanonicalWayPlanResult.fallback;
            }

            const span = WayPackedSpan(
                cast(uint)payloadBase,
                cast(uint)payload.length);

            final switch (field.number)
            {
                case 2:
                    if (seenKeys)
                    {
                        status = PbfStatus.init;
                        return CanonicalWayPlanResult.fallback;
                    }
                    seenKeys = true;
                    keyPayload = payload;
                    keyPayloadBase = payloadBase;
                    keys = span;
                    break;

                case 3:
                    if (seenVals)
                    {
                        status = PbfStatus.init;
                        return CanonicalWayPlanResult.fallback;
                    }
                    seenVals = true;
                    valuePayload = payload;
                    valuePayloadBase = payloadBase;
                    vals = span;
                    break;

                case 8:
                    if (seenRefs)
                    {
                        status = PbfStatus.init;
                        return CanonicalWayPlanResult.fallback;
                    }
                    seenRefs = true;
                    refPayload = payload;
                    refPayloadBase = payloadBase;
                    refs = span;
                    break;

                case 9:
                    if (seenLats)
                    {
                        status = PbfStatus.init;
                        return CanonicalWayPlanResult.fallback;
                    }
                    seenLats = true;
                    latPayload = payload;
                    latPayloadBase = payloadBase;
                    lats = span;
                    break;

                case 10:
                    if (seenLons)
                    {
                        status = PbfStatus.init;
                        return CanonicalWayPlanResult.fallback;
                    }
                    seenLons = true;
                    lonPayload = payload;
                    lonPayloadBase = payloadBase;
                    lons = span;
                    break;
            }

            continue;
        }

        if (!skipFieldValue(cursor, field, wire))
        {
            status = PbfStatus.fromWayWire(wire, wayRef.rawOffset);
            return CanonicalWayPlanResult.error;
        }
    }

    if (!hasId)
    {
        status = PbfStatus.failure(
            PbfError.missingWayId,
            wayRef.rawOffset,
            1);
        return CanonicalWayPlanResult.error;
    }

    if (!finalizeInfo(block, table, parsed.info, status))
        return CanonicalWayPlanResult.error;

    // Preserve the legacy semantic failure order after the single structural
    // field scan: Info, tags, refs, then optional locations.
    if (!validateCanonicalPackedTags(
            keyPayload,
            keyPayloadBase,
            valuePayload,
            valuePayloadBase,
            table,
            parsed.tags,
            status))
    {
        return CanonicalWayPlanResult.error;
    }

    if (!validateCanonicalPackedRefs(
            refPayload,
            refPayloadBase,
            parsed.refs,
            status))
    {
        return CanonicalWayPlanResult.error;
    }

    if (!validateCanonicalPackedCoordinate(
            latPayload,
            latPayloadBase,
            9,
            block.latOffset,
            block.granularity,
            parsed.locations.latCount,
            parsed.locations.finalLat,
            status))
    {
        return CanonicalWayPlanResult.error;
    }

    if (!validateCanonicalPackedCoordinate(
            lonPayload,
            lonPayloadBase,
            10,
            block.lonOffset,
            block.granularity,
            parsed.locations.lonCount,
            parsed.locations.finalLon,
            status))
    {
        return CanonicalWayPlanResult.error;
    }

    if (parsed.locations.hasLocations &&
        (parsed.locations.latCount != parsed.refs.refCount ||
         parsed.locations.lonCount != parsed.refs.refCount))
    {
        status = PbfStatus.failure(
            PbfError.wayLocationColumnLengthMismatch,
            wayRef.rawOffset,
            parsed.locations.latCount != parsed.refs.refCount ? 9 : 10);
        return CanonicalWayPlanResult.error;
    }

    const locationCount =
        parsed.locations.hasLocations
            ? parsed.locations.latCount
            : 0;

    if (wayRef.rawOffset > uint.max ||
        wayRef.bytes.length > uint.max ||
        parsed.tags.tagCount > uint.max ||
        parsed.refs.refCount > uint.max ||
        locationCount > uint.max)
    {
        status = PbfStatus.init;
        return CanonicalWayPlanResult.fallback;
    }

    const rawStart = wayRef.rawOffset;
    const rawLength = wayRef.bytes.length;
    if (rawStart > group.raw.length ||
        rawLength > group.raw.length - rawStart)
    {
        status = PbfStatus.failure(
            PbfError.wayCountMismatch,
            wayRef.rawOffset,
            3);
        return CanonicalWayPlanResult.error;
    }

    plan.id = parsed.id;
    plan.info = compactInfoFromView(parsed.info, table);
    plan.rawOffset = cast(uint)wayRef.rawOffset;
    plan.rawLength = cast(uint)wayRef.bytes.length;
    plan.tagCount = cast(uint)parsed.tags.tagCount;
    plan.refCount = cast(uint)parsed.refs.refCount;
    plan.locationCount = cast(uint)locationCount;
    plan.keys = keys;
    plan.vals = vals;
    plan.refs = refs;
    plan.lats = lats;
    plan.lons = lons;
    plan.canonicalPacked = true;

    status = PbfStatus.init;
    return CanonicalWayPlanResult.success;
}

/**
 * Fully preflight every regular Way into caller-owned reusable plan storage.
 *
 * No observable sink calls occur here. `planCount` remains zero on every
 * failure and is published only after the complete PrimitiveGroup has been
 * semantically validated and its Way occurrence count reproduced.
 *
 * Canonical Ways are validated in one message scan while capturing direct
 * packed payload spans for emission. Legal non-canonical protobuf forms fall
 * back to the established generic `parseWay` correctness path without changing
 * this workspace contract.
 */
package(osm)
bool buildWayDecodePlans(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    WayDecodePlan[] workspace,
    out size_t planCount,
    out PbfStatus status)
    @safe nothrow @nogc
{
    planCount = 0;

    if (group.wayOccurrences == 0)
    {
        status = PbfStatus.init;
        return true;
    }

    if (workspace.length < group.wayOccurrences)
    {
        status = PbfStatus.failure(
            PbfError.wayWorkspaceTooSmall,
            0,
            3);
        return false;
    }

    size_t preparedCount;
    auto ways = WayMessageCursor(group.raw);

    while (true)
    {
        WayMessageRef wayRef;
        bool hasWay;
        if (!ways.next(wayRef, hasWay, status))
            return false;
        if (!hasWay)
            break;

        if (preparedCount >= workspace.length)
        {
            status = PbfStatus.failure(
                PbfError.wayWorkspaceTooSmall,
                wayRef.rawOffset,
                3);
            return false;
        }

        WayDecodePlan candidate;
        const canonicalResult = tryBuildCanonicalWayDecodePlan(
            block,
            group,
            wayRef,
            table,
            candidate,
            status);

        if (canonicalResult == CanonicalWayPlanResult.error)
            return false;

        if (canonicalResult == CanonicalWayPlanResult.fallback)
        {
            ParsedWay parsed;
            if (!parseWay(block, wayRef, table, parsed, status))
                return false;

            const locationCount =
                parsed.locations.hasLocations
                    ? parsed.locations.latCount
                    : 0;

            if (wayRef.rawOffset > uint.max ||
                wayRef.bytes.length > uint.max ||
                parsed.tags.tagCount > uint.max ||
                parsed.refs.refCount > uint.max ||
                locationCount > uint.max)
            {
                status = PbfStatus.failure(
                    PbfError.wayCountMismatch,
                    wayRef.rawOffset,
                    3);
                return false;
            }

            const rawStart = wayRef.rawOffset;
            const rawLength = wayRef.bytes.length;
            if (rawStart > group.raw.length ||
                rawLength > group.raw.length - rawStart)
            {
                status = PbfStatus.failure(
                    PbfError.wayCountMismatch,
                    wayRef.rawOffset,
                    3);
                return false;
            }

            candidate = WayDecodePlan.init;
            candidate.id = parsed.id;
            candidate.info = compactInfoFromView(parsed.info, table);
            candidate.rawOffset = cast(uint)wayRef.rawOffset;
            candidate.rawLength = cast(uint)wayRef.bytes.length;
            candidate.tagCount = cast(uint)parsed.tags.tagCount;
            candidate.refCount = cast(uint)parsed.refs.refCount;
            candidate.locationCount = cast(uint)locationCount;
            candidate.canonicalPacked = false;
        }

        workspace[preparedCount] = candidate;
        ++preparedCount;
    }

    if (preparedCount != group.wayOccurrences)
    {
        status = PbfStatus.failure(
            PbfError.wayCountMismatch,
            0,
            3);
        return false;
    }

    planCount = preparedCount;
    status = PbfStatus.init;
    return true;
}

pragma(inline, true)
private bool sliceWayPlanSpan(
    ref const PrimitiveGroupLayout group,
    WayPackedSpan span,
    uint fieldNumber,
    out const(ubyte)[] payload,
    out PbfStatus status)
    @safe nothrow @nogc
{
    const start = cast(size_t)span.offset;
    const length = cast(size_t)span.length;

    if (start > group.raw.length ||
        length > group.raw.length - start)
    {
        payload = null;
        status = PbfStatus.failure(
            PbfError.wayCountMismatch,
            start,
            fieldNumber);
        return false;
    }

    payload = group.raw[start .. start + length];
    status = PbfStatus.init;
    return true;
}

/**
 * Reconstruct one borrowed WayView from a fully validated reusable plan.
 *
 * Canonical packed plans initialize repeated-field ranges directly from saved
 * payload spans and therefore perform no message-wide repeated-field search.
 * Generic plans preserve all legal segmented/unpacked protobuf forms through
 * the established generic range builders.
 */
package(osm)
bool buildWayFromDecodePlan(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    ref const WayDecodePlan plan,
    out WayView way,
    out PbfStatus status)
    @safe nothrow @nogc
{
    way = WayView.init;

    const rawStart = cast(size_t)plan.rawOffset;
    const rawLength = cast(size_t)plan.rawLength;
    if (rawStart > group.raw.length ||
        rawLength > group.raw.length - rawStart)
    {
        status = PbfStatus.failure(
            PbfError.wayCountMismatch,
            rawStart,
            3);
        return false;
    }

    const raw = group.raw[rawStart .. rawStart + rawLength];

    InfoView info;
    if (!expandCompactInfo(plan.info, table, info))
    {
        status = PbfStatus.failure(
            PbfError.wayCountMismatch,
            rawStart,
            4);
        return false;
    }

    TagValidationSummary tagSummary;
    tagSummary.keyCount = plan.tagCount;
    tagSummary.valueCount = plan.tagCount;

    WayRefValidationSummary refSummary;
    refSummary.refCount = plan.refCount;

    WayLocationValidationSummary locationSummary;
    locationSummary.latCount = plan.locationCount;
    locationSummary.lonCount = plan.locationCount;

    TagRange tags;
    WayRefRange refs;
    WayLocationRange locations;

    if (plan.canonicalPacked)
    {
        const(ubyte)[] keyPayload;
        const(ubyte)[] valuePayload;
        const(ubyte)[] refPayload;
        const(ubyte)[] latPayload;
        const(ubyte)[] lonPayload;

        if (!sliceWayPlanSpan(
                group,
                plan.keys,
                2,
                keyPayload,
                status) ||
            !sliceWayPlanSpan(
                group,
                plan.vals,
                3,
                valuePayload,
                status) ||
            !sliceWayPlanSpan(
                group,
                plan.refs,
                8,
                refPayload,
                status) ||
            !sliceWayPlanSpan(
                group,
                plan.lats,
                9,
                latPayload,
                status) ||
            !sliceWayPlanSpan(
                group,
                plan.lons,
                10,
                lonPayload,
                status))
        {
            return false;
        }

        if (!buildPrevalidatedPackedTagRange(
                keyPayload,
                plan.keys.offset,
                valuePayload,
                plan.vals.offset,
                table,
                tagSummary,
                tags,
                status))
        {
            return false;
        }

        if (!buildPrevalidatedPackedWayRefRange(
                refPayload,
                plan.refs.offset,
                refSummary,
                refs,
                status))
        {
            return false;
        }

        if (!buildPrevalidatedPackedWayLocationRange(
                block,
                latPayload,
                plan.lats.offset,
                lonPayload,
                plan.lons.offset,
                locationSummary,
                locations,
                status))
        {
            return false;
        }
    }
    else
    {
        if (!buildTagRange(
                raw,
                rawStart,
                table,
                tagSummary,
                tags,
                status))
        {
            return false;
        }

        if (!buildWayRefRange(
                raw,
                rawStart,
                refSummary,
                refs,
                status))
        {
            return false;
        }

        if (!buildWayLocationRange(
                block,
                raw,
                rawStart,
                locationSummary,
                locations,
                status))
        {
            return false;
        }
    }

    way = WayView(
        plan.id,
        tags,
        refs,
        locations,
        info,
        raw,
        rawStart);

    status = PbfStatus.init;
    return true;
}

/**
 * Decode one PrimitiveGroup through caller-owned reusable WayDecodePlan storage.
 *
 * The complete group is preflighted before the first sink call. This prototype
 * leaves the existing `decodeWays` entry point unchanged while exercising the
 * production plan path end-to-end.
 */
package(osm)
bool decodeWaysWithWorkspace(Sink)(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    WayDecodePlan[] workspace,
    ref Sink sink,
    out WayDecodeSummary summary,
    out PbfStatus status)
    @safe nothrow @nogc
{
    summary = WayDecodeSummary.init;

    size_t planCount;
    if (!buildWayDecodePlans(
            block,
            group,
            table,
            workspace,
            planCount,
            status))
    {
        return false;
    }

    foreach (ref const plan; workspace[0 .. planCount])
    {
        WayView way;
        if (!buildWayFromDecodePlan(
                block,
                group,
                table,
                plan,
                way,
                status))
        {
            return false;
        }

        sink.put(way);

        ++summary.wayCount;
        summary.tagCount += plan.tagCount;
        summary.refCount += plan.refCount;
        summary.locationCount += plan.locationCount;
    }

    if (summary.wayCount != planCount ||
        summary.wayCount != group.wayOccurrences)
    {
        status = PbfStatus.failure(
            PbfError.wayCountMismatch,
            0,
            3);
        return false;
    }

    status = PbfStatus.init;
    return true;
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
 * This helper is used only by the emission pass after the complete backing
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
        if (!readSVarint64FailureOnly(packed, ignored, wire))
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
 * Precondition: `wayRef.bytes` are the same bytes previously accepted by
 * `parseWay`, unchanged since validation, with the same PrimitiveBlock and
 * StringTable. The first pass has
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
            if (!readSVarint64FailureOnly(cursor, ignored, wire))
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
    // them for the same bytes, unchanged since validation, before this function
    // can run.
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
package(osm)
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
package(osm)
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
 * Build a borrowed absolute-reference range directly from one prevalidated
 * canonical packed refs payload.
 *
 * Unlike `buildWayRefRange`, this path performs no Way message field search.
 */
package(osm)
bool buildPrevalidatedPackedWayRefRange(
    const(ubyte)[] payload,
    size_t payloadBase,
    WayRefValidationSummary summary,
    out WayRefRange range,
    out PbfStatus status)
    @safe nothrow @nogc
{
    range = WayRefRange.init;
    range._deltas = SInt64FieldCursor.fromPrevalidatedPacked(
        payload,
        payloadBase,
        8);
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
            status = PbfStatus.failure(
                PbfError.wayCountMismatch,
                payloadBase,
                8);
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
package(osm)
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
package(osm)
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

/**
 * Build the borrowed optional location range directly from prevalidated
 * canonical packed latitude and longitude payloads.
 *
 * Unlike `buildWayLocationRange`, this path performs no Way message field
 * search.
 */
package(osm)
bool buildPrevalidatedPackedWayLocationRange(
    ref const PrimitiveBlockLayout block,
    const(ubyte)[] latPayload,
    size_t latPayloadBase,
    const(ubyte)[] lonPayload,
    size_t lonPayloadBase,
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

    range._lats = SInt64FieldCursor.fromPrevalidatedPacked(
        latPayload,
        latPayloadBase,
        9);
    range._lons = SInt64FieldCursor.fromPrevalidatedPacked(
        lonPayload,
        lonPayloadBase,
        10);
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
                !hasLat ? latPayloadBase : lonPayloadBase,
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
            latPayloadBase,
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

    /**
     * Construct a cursor that starts directly in one already validated packed
     * repeated-field payload.
     *
     * No message-wide field search is performed. The caller must have proved
     * that this payload represents the complete logical repeated column.
     */
    static SInt64FieldCursor fromPrevalidatedPacked(
        const(ubyte)[] packed,
        size_t packedBase,
        uint fieldNumber)
        @safe nothrow @nogc
    {
        SInt64FieldCursor result;
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
    bool next(out long value, out bool hasValue, out PbfStatus status)
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
                    bool ok;
                    auto packed = readLengthDelimitedCursor(
                        _message,
                        field.number,
                        ok,
                        wire);
                    if (!ok)
                    {
                        status = PbfStatus.fromWayWire(wire, _baseOffset);
                        return false;
                    }

                    _packedBase =
                        _baseOffset + _message.offset - packed.remaining;
                    _packed = packed;

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
    assert(tags.frontKeyStringId == 1 && tags.frontValueStringId == 2);
    tags.popFront();
    assert(tags.frontKeyStringId == 3 && tags.frontValueStringId == 4);
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

    auto nodes = sink.way.nodes;
    assert(nodes.length == 3);
    assert(nodes.front.id == 10 && !nodes.front.hasLocation);
    nodes.popFront();
    assert(nodes.front.id == 12 && !nodes.front.hasLocation);
    nodes.popFront();
    assert(nodes.front.id == 11 && !nodes.front.hasLocation);
    nodes.popFront();
    assert(nodes.empty);
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

    auto nodes = sink.way.nodes;
    assert(nodes.length == 2);
    assert(nodes.front.id == 10);
    assert(nodes.front.hasLocation);
    assert(nodes.front.location.latitudeNanodegrees == 11_000);
    assert(nodes.front.location.longitudeNanodegrees == -6_000);
    nodes.popFront();
    assert(nodes.front.id == 12);
    assert(nodes.front.hasLocation);
    assert(nodes.front.location.latitudeNanodegrees == 11_100);
    assert(nodes.front.location.longitudeNanodegrees == -5_800);
    nodes.popFront();
    assert(nodes.empty);
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


unittest
{
    // Canonical packed refs deltas [10, +2, -1] => [10, 12, 11].
    const(ubyte)[] packed = [0x14, 0x04, 0x01];

    WayRefValidationSummary summary;
    summary.refCount = 3;
    summary.finalRef = 11;

    WayRefRange range;
    PbfStatus status;
    assert(buildPrevalidatedPackedWayRefRange(
        packed,
        100,
        summary,
        range,
        status));
    assert(status.ok);
    assert(range.length == 3);

    assert(range.front == 10);
    range.popFront();
    assert(range.front == 12);
    range.popFront();
    assert(range.front == 11);
    range.popFront();
    assert(range.empty);
}

unittest
{
    // Canonical packed LocationsOnWays:
    // lat-grid deltas [100,+1], lon-grid deltas [-50,+2].
    const(ubyte)[] lats = [0xc8, 0x01, 0x02];
    const(ubyte)[] lons = [0x63, 0x04];

    PrimitiveBlockLayout block;
    block.granularity = 100;
    block.latOffset = 1000;
    block.lonOffset = -1000;

    WayLocationValidationSummary summary;
    summary.latCount = 2;
    summary.lonCount = 2;
    summary.finalLat = 101;
    summary.finalLon = -48;

    WayLocationRange range;
    PbfStatus status;
    assert(buildPrevalidatedPackedWayLocationRange(
        block,
        lats,
        200,
        lons,
        300,
        summary,
        range,
        status));
    assert(status.ok);
    assert(range.length == 2);

    assert(range.front.latNano == 11_000);
    assert(range.front.lonNano == -6_000);
    range.popFront();

    assert(range.front.latNano == 11_100);
    assert(range.front.lonNano == -5_800);
    range.popFront();

    assert(range.empty);
}


unittest
{
    import osm.io.pbf.string_table : StringRef;

    const(ubyte)[] raw = [0, 'u', 's', 'e', 'r'];
    StringRef[2] refs = [
        StringRef(0, 0),
        StringRef(1, 4),
    ];
    StringTableView table = StringTableView(raw, refs[]);

    InfoView original;
    original.hasVersion = true;
    original.version_ = 7;
    original.hasTimestamp = true;
    original.timestampValue = 123;
    original.timestampMillis = 12_300;
    original.hasChangeset = true;
    original.changeset = 456;
    original.hasUid = true;
    original.uid = 789;
    original.hasUser = true;
    original.userSid = 1;
    original.user = raw[1 .. 5];
    original.hasVisible = true;
    original.visible = false;

    const compact = compactInfoFromView(original, table);

    InfoView expanded;
    assert(expandCompactInfo(compact, table, expanded));

    assert(expanded.hasVersion);
    assert(expanded.version_ == 7);
    assert(expanded.hasTimestamp);
    assert(expanded.timestampValue == 123);
    assert(expanded.timestampMillis == 12_300);
    assert(expanded.hasChangeset);
    assert(expanded.changeset == 456);
    assert(expanded.hasUid);
    assert(expanded.uid == 789);
    assert(expanded.hasUser);
    assert(expanded.userSid == 1);
    assert(expanded.user == raw[1 .. 5]);
    assert(expanded.hasVisible);
    assert(!expanded.visible);
}


unittest
{
    // One minimal Way: PrimitiveGroup field 3 -> Way { id = 7 }.
    const(ubyte)[] groupBytes = [
        0x1a, 0x02,
        0x08, 0x07,
    ];

    PrimitiveBlockLayout block;

    PrimitiveGroupLayout group;
    group.raw = groupBytes;
    group.wayOccurrences = 1;

    StringTableView table;
    WayDecodePlan[1] plans;
    size_t planCount;
    PbfStatus status;

    assert(buildWayDecodePlans(
        block,
        group,
        table,
        plans[],
        planCount,
        status));
    assert(status.ok);
    assert(planCount == 1);

    assert(plans[0].id == 7);
    assert(plans[0].rawOffset == 2);
    assert(plans[0].rawLength == 2);
    assert(plans[0].tagCount == 0);
    assert(plans[0].refCount == 0);
    assert(plans[0].locationCount == 0);

    // All repeated columns are absent, which is canonical by definition.
    assert(plans[0].canonicalPacked);
}

unittest
{
    // Capacity failure must happen before semantic traversal and publish no plan.
    PrimitiveBlockLayout block;

    PrimitiveGroupLayout group;
    group.raw = [0xff];
    group.wayOccurrences = 1;

    StringTableView table;
    WayDecodePlan[] noWorkspace;
    size_t planCount = size_t.max;
    PbfStatus status;

    assert(!buildWayDecodePlans(
        block,
        group,
        table,
        noWorkspace,
        planCount,
        status));
    assert(status.error == PbfError.wayWorkspaceTooSmall);
    assert(status.fieldNumber == 3);
    assert(planCount == 0);
}


unittest
{
    // Later malformed Way must leave planCount unpublished.
    //
    // Way #1 is valid: { id = 7 }.
    // Way #2 contains field 1 with a truncated varint.
    const(ubyte)[] groupBytes = [
        0x1a, 0x02,
        0x08, 0x07,

        0x1a, 0x01,
        0x08,
    ];

    PrimitiveBlockLayout block;

    PrimitiveGroupLayout group;
    group.raw = groupBytes;
    group.wayOccurrences = 2;

    StringTableView table;
    WayDecodePlan[2] plans;
    size_t planCount = size_t.max;
    PbfStatus status;

    assert(!buildWayDecodePlans(
        block,
        group,
        table,
        plans[],
        planCount,
        status));

    assert(status.error == PbfError.invalidWayWire);
    assert(status.fieldNumber == 1);

    // The first scratch slot may have been written, but no entry is published
    // until the complete PrimitiveGroup has passed semantic preflight.
    assert(plans[0].id == 7);
    assert(planCount == 0);
}


unittest
{
    // Canonical packed refs are discovered and semantically validated during
    // the same Way field scan that creates the emission plan.
    //
    // refs deltas [10,+2,-1] => absolute refs [10,12,11].
    const(ubyte)[] groupBytes = [
        0x1a, 0x07,
        0x08, 0x07,
        0x42, 0x03, 0x14, 0x04, 0x01,
    ];

    PrimitiveBlockLayout block;

    PrimitiveGroupLayout group;
    group.raw = groupBytes;
    group.wayOccurrences = 1;

    StringTableView table;
    WayDecodePlan[1] plans;
    size_t planCount;
    PbfStatus status;

    assert(buildWayDecodePlans(
        block,
        group,
        table,
        plans[],
        planCount,
        status));
    assert(status.ok);
    assert(planCount == 1);

    assert(plans[0].canonicalPacked);
    assert(plans[0].id == 7);
    assert(plans[0].rawOffset == 2);
    assert(plans[0].rawLength == 7);
    assert(plans[0].refCount == 3);
    assert(plans[0].refs.offset == 6);
    assert(plans[0].refs.length == 3);
}

unittest
{
    // Legal unpacked repeated refs are deliberately routed through the
    // established generic parser rather than rejected by the fast path.
    const(ubyte)[] groupBytes = [
        0x1a, 0x06,
        0x08, 0x07,
        0x40, 0x14,
        0x40, 0x04,
    ];

    PrimitiveBlockLayout block;

    PrimitiveGroupLayout group;
    group.raw = groupBytes;
    group.wayOccurrences = 1;

    StringTableView table;
    WayDecodePlan[1] plans;
    size_t planCount;
    PbfStatus status;

    assert(buildWayDecodePlans(
        block,
        group,
        table,
        plans[],
        planCount,
        status));
    assert(status.ok);
    assert(planCount == 1);

    assert(!plans[0].canonicalPacked);
    assert(plans[0].id == 7);
    assert(plans[0].refCount == 2);
}


unittest
{
    // Canonical packed refs must emit through the saved packed payload span
    // without changing public WayRefRange semantics.
    const(ubyte)[] groupBytes = [
        0x1a, 0x07,
        0x08, 0x07,
        0x42, 0x03, 0x14, 0x04, 0x01,
    ];

    PrimitiveBlockLayout block;

    PrimitiveGroupLayout group;
    group.raw = groupBytes;
    group.wayOccurrences = 1;

    StringTableView table;
    WayDecodePlan[1] plans;
    size_t planCount;
    PbfStatus status;

    assert(buildWayDecodePlans(
        block,
        group,
        table,
        plans[],
        planCount,
        status));
    assert(planCount == 1);
    assert(plans[0].canonicalPacked);

    WayView way;
    assert(buildWayFromDecodePlan(
        block,
        group,
        table,
        plans[0],
        way,
        status));
    assert(status.ok);
    assert(way.id == 7);
    assert(way.raw == groupBytes[2 .. 9]);

    auto refs = way.refs;
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
    // Unpacked refs must retain the same borrowed range behavior through the
    // generic fallback plan.
    const(ubyte)[] groupBytes = [
        0x1a, 0x06,
        0x08, 0x07,
        0x40, 0x14,
        0x40, 0x04,
    ];

    PrimitiveBlockLayout block;

    PrimitiveGroupLayout group;
    group.raw = groupBytes;
    group.wayOccurrences = 1;

    StringTableView table;
    WayDecodePlan[1] plans;
    size_t planCount;
    PbfStatus status;

    assert(buildWayDecodePlans(
        block,
        group,
        table,
        plans[],
        planCount,
        status));
    assert(planCount == 1);
    assert(!plans[0].canonicalPacked);

    WayView way;
    assert(buildWayFromDecodePlan(
        block,
        group,
        table,
        plans[0],
        way,
        status));
    assert(status.ok);

    auto refs = way.refs;
    assert(refs.length == 2);
    assert(refs.front == 10);
    refs.popFront();
    assert(refs.front == 12);
    refs.popFront();
    assert(refs.empty);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential contract: legacy decodeWays and plan-backed decoding must
    // expose identical semantics for a normal canonical Way.
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
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);

    assert(legacySummary.wayCount == planSummary.wayCount);
    assert(legacySummary.tagCount == planSummary.tagCount);
    assert(legacySummary.refCount == planSummary.refCount);
    assert(legacySummary.locationCount == planSummary.locationCount);

    assert(legacySink.used == 1);
    assert(planSink.used == 1);

    assert(legacySink.way.id == planSink.way.id);
    assert(legacySink.way.raw == planSink.way.raw);

    assert(legacySink.way.info.hasVersion == planSink.way.info.hasVersion);
    assert(legacySink.way.info.version_ == planSink.way.info.version_);
    assert(legacySink.way.info.hasTimestamp == planSink.way.info.hasTimestamp);
    assert(legacySink.way.info.timestampValue ==
        planSink.way.info.timestampValue);
    assert(legacySink.way.info.timestampMillis ==
        planSink.way.info.timestampMillis);
    assert(legacySink.way.info.hasChangeset ==
        planSink.way.info.hasChangeset);
    assert(legacySink.way.info.changeset == planSink.way.info.changeset);
    assert(legacySink.way.info.hasUid == planSink.way.info.hasUid);
    assert(legacySink.way.info.uid == planSink.way.info.uid);
    assert(legacySink.way.info.hasUser == planSink.way.info.hasUser);
    assert(legacySink.way.info.userSid == planSink.way.info.userSid);
    assert(legacySink.way.info.user == planSink.way.info.user);
    assert(legacySink.way.info.hasVisible == planSink.way.info.hasVisible);
    assert(legacySink.way.info.visible == planSink.way.info.visible);

    auto legacyTags = legacySink.way.tags;
    auto planTags = planSink.way.tags;
    assert(legacyTags.length == planTags.length);
    while (!legacyTags.empty)
    {
        assert(!planTags.empty);
        assert(legacyTags.frontKeyStringId == planTags.frontKeyStringId);
        assert(legacyTags.frontValueStringId == planTags.frontValueStringId);
        assert(legacyTags.front.key == planTags.front.key);
        assert(legacyTags.front.value == planTags.front.value);
        legacyTags.popFront();
        planTags.popFront();
    }
    assert(planTags.empty);

    auto legacyRefs = legacySink.way.refs;
    auto planRefs = planSink.way.refs;
    assert(legacyRefs.length == planRefs.length);
    while (!legacyRefs.empty)
    {
        assert(!planRefs.empty);
        assert(legacyRefs.front == planRefs.front);
        legacyRefs.popFront();
        planRefs.popFront();
    }
    assert(planRefs.empty);

    assert(legacySink.way.locations.empty);
    assert(planSink.way.locations.empty);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential success: canonical packed LocationsOnWays must expose the
    // same aligned exact nanodegree range through the plan-backed decoder.
    const(ubyte)[] groupBytes = [
        0x1a, 0x0f,
        0x08, 0x01,
        0x42, 0x02, 0x14, 0x04,
        0x4a, 0x03, 0xc8, 0x01, 0x02,
        0x52, 0x02, 0x63, 0x04,
    ];

    PrimitiveGroupLayout group;
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));

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
        size_t used;

        void put(WayView value) @safe nothrow @nogc
        {
            way = value;
            ++used;
        }
    }

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(workspace[0].canonicalPacked);
    assert(workspace[0].locationCount == 2);

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);

    assert(legacySummary.wayCount == planSummary.wayCount);
    assert(legacySummary.tagCount == planSummary.tagCount);
    assert(legacySummary.refCount == planSummary.refCount);
    assert(legacySummary.locationCount == planSummary.locationCount);
    assert(planSummary.locationCount == 2);

    assert(legacySink.used == 1);
    assert(planSink.used == 1);
    assert(legacySink.way.id == planSink.way.id);
    assert(legacySink.way.raw == planSink.way.raw);

    auto legacyRefs = legacySink.way.refs;
    auto planRefs = planSink.way.refs;
    assert(legacyRefs.length == planRefs.length);
    while (!legacyRefs.empty)
    {
        assert(!planRefs.empty);
        assert(legacyRefs.front == planRefs.front);
        legacyRefs.popFront();
        planRefs.popFront();
    }
    assert(planRefs.empty);

    auto legacyLocations = legacySink.way.locations;
    auto planLocations = planSink.way.locations;
    assert(legacyLocations.length == planLocations.length);
    assert(planLocations.length == 2);

    while (!legacyLocations.empty)
    {
        assert(!planLocations.empty);
        assert(legacyLocations.front.latNano ==
            planLocations.front.latNano);
        assert(legacyLocations.front.lonNano ==
            planLocations.front.lonNano);

        legacyLocations.popFront();
        planLocations.popFront();
    }

    assert(planLocations.empty);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential fallback: duplicate singular ID plus interleaved unpacked
    // and packed refs must retain generic protobuf semantics exactly.
    const(ubyte)[] groupBytes = [
        0x1a, 0x0a,
        0x08, 0x01,
        0x40, 0x0a,
        0x08, 0x07,
        0x42, 0x02, 0x04, 0x01,
    ];

    PrimitiveGroupLayout group;
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(!workspace[0].canonicalPacked);

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);

    assert(legacySummary.wayCount == planSummary.wayCount);
    assert(legacySummary.tagCount == planSummary.tagCount);
    assert(legacySummary.refCount == planSummary.refCount);
    assert(legacySummary.locationCount == planSummary.locationCount);

    assert(legacySink.used == planSink.used);
    assert(legacySink.way.id == planSink.way.id);
    assert(legacySink.way.raw == planSink.way.raw);

    auto legacyRefs = legacySink.way.refs;
    auto planRefs = planSink.way.refs;
    assert(legacyRefs.length == planRefs.length);
    while (!legacyRefs.empty)
    {
        assert(!planRefs.empty);
        assert(legacyRefs.front == planRefs.front);
        legacyRefs.popFront();
        planRefs.popFront();
    }
    assert(planRefs.empty);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential failure: Way.id with the wrong wire type is ignored as an
    // unknown representation, leaving the required semantic ID absent.
    const(ubyte)[] groupBytes = [
        0x1a, 0x03,
        0x0a, 0x01, 0x07,
    ];

    PrimitiveGroupLayout group;
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(!decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(!decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);
    assert(legacySink.used == 0);
    assert(planSink.used == 0);
    assert(legacySummary.wayCount == 0);
    assert(planSummary.wayCount == 0);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential success: Info with the wrong wire type is skipped exactly
    // like an unknown field representation while a valid Way.id remains usable.
    const(ubyte)[] groupBytes = [
        0x1a, 0x04,
        0x08, 0x01,
        0x20, 0x07,
    ];

    PrimitiveGroupLayout group;
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(workspace[0].canonicalPacked);

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);

    assert(legacySummary.wayCount == planSummary.wayCount);
    assert(legacySummary.tagCount == planSummary.tagCount);
    assert(legacySummary.refCount == planSummary.refCount);
    assert(legacySummary.locationCount == planSummary.locationCount);

    assert(legacySink.used == 1);
    assert(planSink.used == 1);
    assert(legacySink.way.id == 1);
    assert(planSink.way.id == 1);
    assert(legacySink.way.raw == planSink.way.raw);

    assert(!legacySink.way.info.hasVersion);
    assert(!legacySink.way.info.hasTimestamp);
    assert(!legacySink.way.info.hasChangeset);
    assert(!legacySink.way.info.hasUid);
    assert(!legacySink.way.info.hasUser);
    assert(!legacySink.way.info.hasVisible);

    assert(legacySink.way.info.hasVersion == planSink.way.info.hasVersion);
    assert(legacySink.way.info.hasTimestamp == planSink.way.info.hasTimestamp);
    assert(legacySink.way.info.hasChangeset == planSink.way.info.hasChangeset);
    assert(legacySink.way.info.hasUid == planSink.way.info.hasUid);
    assert(legacySink.way.info.hasUser == planSink.way.info.hasUser);
    assert(legacySink.way.info.hasVisible == planSink.way.info.hasVisible);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential failure: malformed canonical packed refs must preserve the
    // exact legacy PbfStatus and remain fail-closed.
    const(ubyte)[] groupBytes = [
        0x1a, 0x05,
        0x08, 0x01,
        0x42, 0x01, 0x80,
    ];

    PrimitiveGroupLayout group;
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(!decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(!decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);
    assert(legacySink.used == 0);
    assert(planSink.used == 0);
    assert(legacySummary.wayCount == 0);
    assert(planSummary.wayCount == 0);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential failure: a canonical packed tag SID outside the StringTable
    // must preserve the exact legacy PbfStatus and remain fail-closed.
    const(ubyte)[] groupBytes = [
        0x1a, 0x08,
        0x08, 0x01,
        0x12, 0x01, 0x01,
        0x1a, 0x01, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(!decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(!decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);
    assert(legacySink.used == 0);
    assert(planSink.used == 0);
    assert(legacySummary.wayCount == 0);
    assert(planSummary.wayCount == 0);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential failure: canonical LocationsOnWays coordinate arithmetic
    // overflow must preserve the exact legacy PbfStatus and remain fail-closed.
    const(ubyte)[] groupBytes = [
        0x1a, 0x0b,
        0x08, 0x01,
        0x42, 0x01, 0x02,
        0x4a, 0x01, 0x02,
        0x52, 0x01, 0x00,
    ];

    PrimitiveGroupLayout group;
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));

    PrimitiveBlockLayout block;
    block.granularity = 100;
    block.latOffset = long.max;
    block.lonOffset = 0;

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(!decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(!decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);
    assert(legacySink.used == 0);
    assert(planSink.used == 0);
    assert(legacySummary.wayCount == 0);
    assert(planSummary.wayCount == 0);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential failure: misaligned LocationsOnWays columns.
    const(ubyte)[] groupBytes = [
        0x1a, 0x0d,
        0x08, 0x01,
        0x42, 0x02, 0x02, 0x02,
        0x4a, 0x01, 0x02,
        0x52, 0x02, 0x02, 0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(!decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(!decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);
    assert(legacySink.used == 0);
    assert(planSink.used == 0);
    assert(legacySummary.wayCount == 0);
    assert(planSummary.wayCount == 0);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential failure: a late ref overflow in Way #2 must remain
    // completely fail-closed and return the identical status.
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
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(!decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[2] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(!decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);
    assert(legacySink.used == 0);
    assert(planSink.used == 0);
    assert(legacySummary.wayCount == 0);
    assert(planSummary.wayCount == 0);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential failure: missing required Way ID.
    const(ubyte)[] groupBytes = [0x1a, 0x00];

    PrimitiveGroupLayout group;
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(!decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(!decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);
    assert(legacySink.used == 0);
    assert(planSink.used == 0);
    assert(legacySummary.wayCount == 0);
    assert(planSummary.wayCount == 0);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential failure precedence: Info finalization must retain legacy priority
    // over tag validation even when an invalid canonical packed tag appears first
    // in wire order.
    const(ubyte)[] groupBytes = [
        0x1a, 0x0c,
        0x08, 0x01,
        0x12, 0x01, 0x01,
        0x1a, 0x01, 0x01,
        0x22, 0x02, 0x28, 0x01,
    ];

    PrimitiveGroupLayout group;
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));
    assert(group.wayOccurrences == 1);

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(!decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(!decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(legacyStatus.error == PbfError.infoUserStringIdOutOfRange);
    assert(legacyStatus.fieldNumber == 5);

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);

    assert(legacySink.used == 0);
    assert(planSink.used == 0);
    assert(legacySummary.wayCount == 0);
    assert(planSummary.wayCount == 0);
}


unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential failure precedence: tags must retain legacy priority over refs
    // even when the overflowing refs field appears first in wire order.
    const(ubyte)[] groupBytes = [
        0x1a, 0x15,
        0x08, 0x01,
        0x42, 0x0b,
        0xfe, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
        0x02,
        0x12, 0x01, 0x01,
        0x1a, 0x01, 0x01,
    ];

    PrimitiveGroupLayout group;
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));
    assert(group.wayOccurrences == 1);

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(!decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(!decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(legacyStatus.error == PbfError.tagStringIdOutOfRange);
    assert(legacyStatus.fieldNumber == 2);

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);

    assert(legacySink.used == 0);
    assert(planSink.used == 0);
    assert(legacySummary.wayCount == 0);
    assert(planSummary.wayCount == 0);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential failure precedence: refs must retain legacy priority over
    // LocationsOnWays even when the overflowing coordinate appears first.
    const(ubyte)[] groupBytes = [
        0x1a, 0x15,
        0x08, 0x01,
        0x4a, 0x01, 0x02,
        0x52, 0x01, 0x00,
        0x42, 0x0b,
        0xfe, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x01,
        0x02,
    ];

    PrimitiveGroupLayout group;
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));
    assert(group.wayOccurrences == 1);

    PrimitiveBlockLayout block;
    block.granularity = 100;
    block.latOffset = long.max;
    block.lonOffset = 0;

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(!decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(!decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(legacyStatus.error == PbfError.wayRefOverflow);
    assert(legacyStatus.fieldNumber == 8);

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);

    assert(legacySink.used == 0);
    assert(planSink.used == 0);
    assert(legacySummary.wayCount == 0);
    assert(planSummary.wayCount == 0);
}

unittest
{
    import osm.io.pbf.primitive_group : decodePrimitiveGroupLayout;
    import osm.io.pbf.string_table : StringRef;

    // Differential fallback: two canonical packed refs segments are legal
    // protobuf repeated-field encoding and must retain generic concatenation
    // semantics rather than being rejected by the narrow one-span fast path.
    //
    // Deltas [10] + [2, -1] => absolute refs [10, 12, 11].
    const(ubyte)[] groupBytes = [
        0x1a, 0x09,
        0x08, 0x01,
        0x42, 0x01, 0x14,
        0x42, 0x02, 0x04, 0x01,
    ];

    PrimitiveGroupLayout group;
    PbfStatus layoutStatus;
    assert(decodePrimitiveGroupLayout(groupBytes, group, layoutStatus));
    assert(group.wayOccurrences == 1);

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

    Sink legacySink;
    WayDecodeSummary legacySummary;
    PbfStatus legacyStatus;
    assert(decodeWays(
        block,
        group,
        table,
        legacySink,
        legacySummary,
        legacyStatus));

    WayDecodePlan[1] workspace;
    Sink planSink;
    WayDecodeSummary planSummary;
    PbfStatus planStatus;
    assert(decodeWaysWithWorkspace(
        block,
        group,
        table,
        workspace[],
        planSink,
        planSummary,
        planStatus));

    assert(!workspace[0].canonicalPacked);

    assert(legacyStatus.error == planStatus.error);
    assert(legacyStatus.offset == planStatus.offset);
    assert(legacyStatus.fieldNumber == planStatus.fieldNumber);
    assert(legacyStatus.wireError == planStatus.wireError);

    assert(legacySummary.wayCount == planSummary.wayCount);
    assert(legacySummary.tagCount == planSummary.tagCount);
    assert(legacySummary.refCount == planSummary.refCount);
    assert(legacySummary.locationCount == planSummary.locationCount);

    assert(legacySink.used == 1);
    assert(planSink.used == 1);
    assert(legacySink.way.id == planSink.way.id);
    assert(legacySink.way.raw == planSink.way.raw);

    auto legacyRefs = legacySink.way.refs;
    auto planRefs = planSink.way.refs;

    assert(legacyRefs.length == 3);
    assert(planRefs.length == 3);

    const long[3] expected = [10, 12, 11];
    foreach (value; expected)
    {
        assert(!legacyRefs.empty);
        assert(!planRefs.empty);
        assert(legacyRefs.front == value);
        assert(planRefs.front == value);
        legacyRefs.popFront();
        planRefs.popFront();
    }

    assert(legacyRefs.empty);
    assert(planRefs.empty);
}
