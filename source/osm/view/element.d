/**
 * Format-independent contracts for borrowed OpenStreetMap element views.
 *
 * Concrete codecs retain their own borrowed value representations. This module
 * defines only the semantic identity surface shared by those representations.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-19
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.view.element;

import std.traits : Unqual;

/** Signed OpenStreetMap element identifier. */
alias OsmId = long;

/** Semantic OpenStreetMap element kind. */
enum ElementType : ubyte
{
    node,
    way,
    relation,
}

/**
 * Whether `T` satisfies the common borrowed element-view identity contract.
 *
 * A conforming type exposes exact `ElementType` and `OsmId` values through
 * `type` and `id` from an `@safe nothrow @nogc` borrowed access path.
 *
 * The concrete representation remains codec-owned; satisfying this predicate
 * does not imply one common binary layout.
 */
enum bool isElementView(T) =
    __traits(compiles, (scope ref const T value)
        @safe nothrow @nogc
    {
        static assert(is(Unqual!(typeof(value.type)) == ElementType));
        static assert(is(Unqual!(typeof(value.id)) == OsmId));

        ElementType type = value.type;
        OsmId id = value.id;
    });

unittest
{
    struct FieldView
    {
        ElementType type;
        OsmId id;
    }

    static assert(isElementView!FieldView);
}

unittest
{
    struct PropertyView
    {
    private:
        ElementType _type;
        OsmId _id;

    public:
        @property ElementType type() const scope
            @safe pure nothrow @nogc
        {
            return _type;
        }

        @property OsmId id() const scope
            @safe pure nothrow @nogc
        {
            return _id;
        }
    }

    static assert(isElementView!PropertyView);
}

unittest
{
    struct MissingType
    {
        OsmId id;
    }

    struct MissingId
    {
        ElementType type;
    }

    struct WrongType
    {
        ubyte type;
        OsmId id;
    }

    struct WrongId
    {
        ElementType type;
        int id;
    }

    static assert(!isElementView!MissingType);
    static assert(!isElementView!MissingId);
    static assert(!isElementView!WrongType);
    static assert(!isElementView!WrongId);
}
