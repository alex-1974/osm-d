/**
 * Shared PBF-backed semantic node view.
 *
 * Regular OSMPBF Node messages and DenseNodes use different wire layouts, but
 * consumers observe the same OSM node semantics. This module keeps the
 * encoding-specific tag cursors and metadata diagnostics below one concrete
 * borrowed NodeView without materializing tags or allocating storage.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-01
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.node_view;

import osm.view.element : ElementType, OsmId, isElementView;
import osm.view.location : LocationView;
import osm.view.metadata : MetadataView;
import osm.view.tag : TagView;
import osm.io.pbf.dense_info : DenseInfoView;
import osm.io.pbf.dense_tags : DenseTagRange;
import osm.io.pbf.info : InfoView;
import osm.io.pbf.tags : TagRange;

private enum NodeTagKind : ubyte
{
    regular,
    dense,
}

private union NodeTagState
{
    TagRange regular;
    DenseTagRange dense;
}

/**
 * Borrowed semantic tag range for one PBF-backed node.
 *
 * The two PBF encodings retain specialized internal cursors. The wrapper adds
 * only a stable encoding discriminator and delegates traversal without copying
 * or materializing tag strings. Range copies remain independent because the
 * complete cursor state is stored inline.
 */
struct NodeTagRange
{
private:
    NodeTagState _state;
    size_t _remaining;
    NodeTagKind _kind;

package(osm):
    this(return scope TagRange tags) @safe nothrow @nogc
    {
        _kind = NodeTagKind.regular;
        _remaining = tags.length;
        setRegular(tags);
    }

    this(return scope DenseTagRange tags) @safe nothrow @nogc
    {
        _kind = NodeTagKind.dense;
        _remaining = tags.length;
        setDense(tags);
    }

    /**
     * Current PBF StringTable ID of the key for diagnostics/benchmarks.
     *
     * This is intentionally package-internal and not part of OSM semantics.
     */
    pragma(inline, true)
    @property uint frontKeyStringId() const scope @safe nothrow @nogc
    in (!empty)
    {
        final switch (_kind)
        {
        case NodeTagKind.regular:
            return regularKeyId();
        case NodeTagKind.dense:
            return denseKeyId();
        }
    }

    /**
     * Current PBF StringTable ID of the value for diagnostics/benchmarks.
     *
     * This is intentionally package-internal and not part of OSM semantics.
     */
    pragma(inline, true)
    @property uint frontValueStringId() const scope @safe nothrow @nogc
    in (!empty)
    {
        final switch (_kind)
        {
        case NodeTagKind.regular:
            return regularValueId();
        case NodeTagKind.dense:
            return denseValueId();
        }
    }

public:
    /** Returns true when no tag remains. */
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

    /** Return the current semantic tag. */
    pragma(inline, true)
    @property TagView front() const return scope @safe nothrow @nogc
    in (!empty)
    {
        final switch (_kind)
        {
        case NodeTagKind.regular:
            return regularFront();
        case NodeTagKind.dense:
            return denseFront();
        }
    }

    /** Advance to the next already validated tag. */
    pragma(inline, true)
    void popFront() scope @safe nothrow @nogc
    in (!empty)
    {
        final switch (_kind)
        {
        case NodeTagKind.regular:
            _remaining = popRegular();
            return;
        case NodeTagKind.dense:
            _remaining = popDense();
            return;
        }
    }

private:
    /*
     * DMD correctly rejects direct @safe access to overlapped union members
     * that contain slices. Each helper below is the minimal trusted boundary:
     * _kind is construction-controlled, asserted before access, and the active
     * member is copied or traversed only according to that invariant.
     */
    pragma(inline, true)
    void setRegular(return scope TagRange tags)
        scope @trusted nothrow @nogc
    {
        assert(_kind == NodeTagKind.regular);
        _state.regular = tags;
    }

    pragma(inline, true)
    void setDense(return scope DenseTagRange tags)
        scope @trusted nothrow @nogc
    {
        assert(_kind == NodeTagKind.dense);
        _state.dense = tags;
    }

    pragma(inline, true)
    TagView regularFront() const return scope @trusted nothrow @nogc
    {
        assert(_kind == NodeTagKind.regular);
        return _state.regular.front;
    }

    pragma(inline, true)
    TagView denseFront() const return scope @trusted nothrow @nogc
    {
        assert(_kind == NodeTagKind.dense);
        return _state.dense.front;
    }

    pragma(inline, true)
    size_t popRegular() scope @trusted nothrow @nogc
    {
        assert(_kind == NodeTagKind.regular);
        _state.regular.popFront();
        return _state.regular.length;
    }

    pragma(inline, true)
    size_t popDense() scope @trusted nothrow @nogc
    {
        assert(_kind == NodeTagKind.dense);
        _state.dense.popFront();
        return _state.dense.length;
    }

    pragma(inline, true)
    uint regularKeyId() const scope @trusted nothrow @nogc
    {
        assert(_kind == NodeTagKind.regular);
        return _state.regular.frontKeyStringId;
    }

    pragma(inline, true)
    uint denseKeyId() const scope @trusted nothrow @nogc
    {
        assert(_kind == NodeTagKind.dense);
        return _state.dense.frontKeyStringId;
    }

    pragma(inline, true)
    uint regularValueId() const scope @trusted nothrow @nogc
    {
        assert(_kind == NodeTagKind.regular);
        return _state.regular.frontValueStringId;
    }

    pragma(inline, true)
    uint denseValueId() const scope @trusted nothrow @nogc
    {
        assert(_kind == NodeTagKind.dense);
        return _state.dense.frontValueStringId;
    }
}

/**
 * Encoding-neutralized PBF metadata state retained for internal diagnostics.
 *
 * The public metadata property projects this state into MetadataView. The raw
 * PBF timestamp value and StringTable user ID stay package-internal so existing
 * decoder benchmarks can preserve their historical checksum semantics.
 */
package(osm)
struct NodeInfoState
{
    bool hasVersion;
    int version_ = -1;

    bool hasTimestamp;
    long timestampValue;
    long timestampMillis;

    bool hasChangeset;
    long changeset;

    bool hasUid;
    int uid;

    bool hasUser;
    uint userSid;
    const(ubyte)[] user;

    bool hasVisible;
    bool visible;

    this(return scope InfoView info) @safe pure nothrow @nogc
    {
        copyFrom(info);
    }

    this(return scope DenseInfoView info) @safe pure nothrow @nogc
    {
        copyFrom(info);
    }

private:
    void copyFrom(T)(return scope T info) @safe pure nothrow @nogc
    {
        hasVersion = info.hasVersion;
        version_ = info.version_;
        hasTimestamp = info.hasTimestamp;
        timestampValue = info.timestampValue;
        timestampMillis = info.timestampMillis;
        hasChangeset = info.hasChangeset;
        changeset = info.changeset;
        hasUid = info.hasUid;
        uid = info.uid;
        hasUser = info.hasUser;
        userSid = info.userSid;
        user = info.user;
        hasVisible = info.hasVisible;
        visible = info.visible;
    }
}

/**
 * One concrete borrowed PBF node view for regular Node and DenseNodes encoding.
 *
 * Public fields/properties describe OSM semantics. PBF coordinate backing and
 * diagnostic metadata remain package-internal. Tags are zero-copy and retain
 * independent range-copy semantics.
 */
struct NodeView
{
public:
    /// Signed OSM node identifier.
    OsmId id;

package(osm):
    /// Exact latitude in nanodegrees after validated PBF coordinate conversion.
    long latNano;
    /// Exact longitude in nanodegrees after validated PBF coordinate conversion.
    long lonNano;

public:
    /// Borrowed ordered semantic tags.
    NodeTagRange tags;

package(osm):
    /// PBF metadata state retained for diagnostics and semantic projection.
    NodeInfoState info;

    this(
        OsmId id,
        long latNano,
        long lonNano,
        return scope TagRange tags,
        return scope InfoView info)
        @safe nothrow @nogc
    {
        this.id = id;
        this.latNano = latNano;
        this.lonNano = lonNano;
        this.tags = NodeTagRange(tags);
        this.info = NodeInfoState(info);
    }

    this(
        OsmId id,
        long latNano,
        long lonNano,
        return scope DenseTagRange tags,
        return scope DenseInfoView info)
        @safe nothrow @nogc
    {
        this.id = id;
        this.latNano = latNano;
        this.lonNano = lonNano;
        this.tags = NodeTagRange(tags);
        this.info = NodeInfoState(info);
    }

public:
    /** Semantic location with exact integer backing and lazy degree conversion. */
    pragma(inline, true)
    @property LocationView location() const scope
        @safe pure nothrow @nogc
    {
        return LocationView(latNano, lonNano);
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

    /// Semantic OSM element kind.
    @property ElementType type() const scope
        @safe pure nothrow @nogc
    {
        return ElementType.node;
    }
}

static assert(isElementView!NodeView);

unittest
{
    static assert(NodeTagRange.sizeof <= 176);
    static assert(NodeInfoState.sizeof == 88);
    static assert(NodeView.sizeof <= 288);
}

