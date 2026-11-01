/**
 * Shared consumer-facing PBF node view.
 *
 * Regular OSMPBF Node messages and DenseNodes retain their proven codec-owned
 * representations. PbfReader wraps either representation in this small
 * synchronous borrowed view so consumers see one concrete NodeView without
 * copying codec tag cursors or metadata state on every node callback.
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
import osm.io.pbf.dense_nodes : DenseNodeView;
import osm.io.pbf.dense_tags : DenseTagRange;
import osm.io.pbf.node : PbfRegularNodeView = NodeView;
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
 * Independent borrowed semantic tag range for one PBF-backed node.
 *
 * The enclosing NodeView is only a synchronous callback borrow. Requesting
 * `tags` copies the selected proven codec range into this value, after which
 * traversal is independent of the codec view and remains zero-allocation.
 */
struct NodeTagRange
{
private:
    NodeTagState _state;
    size_t _remaining;
    NodeTagKind _kind;

package(osm):
    this(return scope ref TagRange tags) @safe nothrow @nogc
    {
        _kind = NodeTagKind.regular;
        _remaining = tags.length;
        setRegular(tags);
    }

    this(return scope ref DenseTagRange tags) @safe nothrow @nogc
    {
        _kind = NodeTagKind.dense;
        _remaining = tags.length;
        setDense(tags);
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

    /** Advance this independent range copy to the next validated tag. */
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
     * DMD rejects direct @safe access to overlapped union members containing
     * slices. The discriminator is construction-controlled and asserted before
     * each active-member access; only that compiler-unverifiable operation is
     * trusted.
     */
    pragma(inline, true)
    void setRegular(return scope ref TagRange tags)
        scope @trusted nothrow @nogc
    {
        assert(_kind == NodeTagKind.regular);
        _state.regular = tags;
    }

    pragma(inline, true)
    void setDense(return scope ref DenseTagRange tags)
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
}

private enum NodeBackingKind : ubyte
{
    scalars,
    regular,
    dense,
}

/**
 * One concrete semantic node view delivered synchronously by PbfReader.
 *
 * The view is deliberately non-copyable. For regular and dense encoded nodes
 * it borrows the codec view only for the duration of the callback; this keeps
 * construction constant-size and prevents a copied NodeView from outliving the
 * stack object it references. Semantic subviews may be requested normally:
 * `location` and `metadata` are lightweight values, while `tags` returns
 * an independent borrowed range copy.
 *
 * `NodeView.init` is a structurally valid scalar node with id and exact
 * coordinates equal to zero, empty metadata, and no tags.
 */
struct NodeView
{
private:
    PbfRegularNodeView* _regular;
    DenseNodeView* _dense;
    OsmId _scalarId;
    long _scalarLatNano;
    long _scalarLonNano;
    NodeBackingKind _kind;

    // A copied fat reference could outlive the codec-local object it borrows.
    @disable this(this);

package(osm):
    /** Construct the scalar-only DenseNodes fast-path view. */
    this(OsmId id, long latNano, long lonNano)
        @safe pure nothrow @nogc
    {
        _scalarId = id;
        _scalarLatNano = latNano;
        _scalarLonNano = lonNano;
        _kind = NodeBackingKind.scalars;
    }

    /**
     * Borrow one regular codec view for the enclosing synchronous callback.
     *
     * Safety:
     *   PbfReader calls the handler before `encoded` leaves scope. NodeView is
     *   non-copyable and is itself passed as `scope ref`, so the borrowed
     *   pointer cannot be retained through the public value API.
     */
    this(scope ref PbfRegularNodeView encoded)
        @trusted pure nothrow @nogc
    {
        _regular = &encoded;
        _kind = NodeBackingKind.regular;
    }

    /**
     * Borrow one dense codec view for the enclosing synchronous callback.
     *
     * Safety:
     *   PbfReader calls the handler before `encoded` leaves scope. NodeView is
     *   non-copyable and is itself passed as `scope ref`, so the borrowed
     *   pointer cannot be retained through the public value API.
     */
    this(scope ref DenseNodeView encoded)
        @trusted pure nothrow @nogc
    {
        _dense = &encoded;
        _kind = NodeBackingKind.dense;
    }

public:
    /** Signed OSM node identifier. */
    pragma(inline, true)
    @property OsmId id() const scope @safe pure nothrow @nogc
    {
        final switch (_kind)
        {
        case NodeBackingKind.scalars:
            return _scalarId;
        case NodeBackingKind.regular:
            assert(_regular !is null);
            return _regular.id;
        case NodeBackingKind.dense:
            assert(_dense !is null);
            return _dense.id;
        }
    }

    /** Semantic location with exact integer backing and lazy degree conversion. */
    pragma(inline, true)
    @property LocationView location() const scope
        @safe pure nothrow @nogc
    {
        final switch (_kind)
        {
        case NodeBackingKind.scalars:
            return LocationView(_scalarLatNano, _scalarLonNano);
        case NodeBackingKind.regular:
            assert(_regular !is null);
            return _regular.location;
        case NodeBackingKind.dense:
            assert(_dense !is null);
            return _dense.location;
        }
    }

    /** Format-independent OSM metadata. */
    pragma(inline, true)
    @property MetadataView metadata() const return scope
        @safe pure nothrow @nogc
    {
        final switch (_kind)
        {
        case NodeBackingKind.scalars:
            return MetadataView.init;
        case NodeBackingKind.regular:
            assert(_regular !is null);
            return _regular.metadata;
        case NodeBackingKind.dense:
            assert(_dense !is null);
            return _dense.metadata;
        }
    }

    /**
     * Return an independent borrowed range over this node's semantic tags.
     *
     * The codec range is copied only when the consumer actually requests tags.
     * The codec range is borrowed by ref during construction so the independent
     * semantic cursor is copied exactly once into its union storage.
     * No tag cursor or metadata state is copied merely to deliver the node
     * callback.
     */
    pragma(inline, true)
    @property NodeTagRange tags() return scope
        @safe nothrow @nogc
    {
        final switch (_kind)
        {
        case NodeBackingKind.scalars:
            return NodeTagRange.init;
        case NodeBackingKind.regular:
            assert(_regular !is null);
            return NodeTagRange(_regular.tags);
        case NodeBackingKind.dense:
            assert(_dense !is null);
            return NodeTagRange(_dense.tags);
        }
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
    static assert(!__traits(compiles, (scope ref NodeView value)
    {
        NodeView copy = value;
    }));

    // Three scalar values, two codec pointers, and one discriminator plus
    // alignment. Keep this callback adapter small enough that its construction
    // cannot reproduce the former 368-byte per-node copy.
    static if (size_t.sizeof == 8)
        static assert(NodeView.sizeof <= 48);
}
