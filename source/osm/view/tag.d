/**
 * Format-independent borrowed OpenStreetMap tags and lookup algorithms.
 *
 * A tag is exposed as its exact key and value byte sequences. Codec-specific
 * lookup state such as OSMPBF StringTable IDs does not cross this semantic
 * boundary. No normalization, repair, transcoding, or allocation is performed.
 *
 * Both byte slices are borrowed and must not outlive the backing storage owned
 * by the reader or representation that produced the view.
 *
 * The lookup helpers in this module accept ordinary D input ranges whose front
 * value exposes exact byte `key` and `value` slices. They consume only a copy
 * of the supplied range cursor, so querying a borrowed tag range does not
 * advance the caller's cursor.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-01
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.view.tag;

import std.range.primitives : empty, front, isInputRange, popFront;
import std.traits : Unqual;

/**
 * One borrowed semantic OSM tag.
 *
 * Tag ordering and duplicate preservation are properties of the containing
 * range. This value carries no codec-specific lookup identifier.
 */
struct TagView
{
    /// Borrowed exact key bytes.
    const(ubyte)[] key;

    /// Borrowed exact value bytes.
    const(ubyte)[] value;
}

private enum bool isTagCodeUnit(T) =
    is(Unqual!T == ubyte) || is(Unqual!T == char);

private enum bool isSemanticTagRange(R) =
    isInputRange!R &&
    __traits(compiles, (R range)
    {
        auto tag = front(range);
        const(ubyte)[] key = tag.key;
        const(ubyte)[] value = tag.value;
    });

/**
 * Find the first tag with exactly matching key bytes.
 *
 * The query may be supplied as `ubyte[]` or D `char[]`. A D string is
 * compared as its existing UTF-8 code units; no decoding, normalization,
 * transcoding, case folding, or allocation occurs.
 *
 * Duplicate keys are preserved by the underlying range. This function returns
 * the first matching occurrence in range order.
 *
 * Params:
 *   tags = Input range whose front value exposes exact byte `key` and
 *     `value` slices. The range is consumed by value; the caller's cursor is
 *     not advanced.
 *   key = Exact key bytes/code units to match.
 *   tag = Receives the borrowed first matching tag, or `TagView.init` when no
 *     match exists.
 *
 * Returns:
 *   `true` when a matching key exists; otherwise `false`.
 *
 * Safety:
 *   The returned tag borrows the same backing storage as the supplied range.
 *   No allocation or normalization is performed.
 */
bool findTag(R, Q)(
    R tags,
    scope Q[] key,
    out TagView tag)
    @safe nothrow @nogc
if (isSemanticTagRange!R && isTagCodeUnit!Q)
{
    tag = TagView.init;

    while (!empty(tags))
    {
        const current = front(tags);
        if (sameBytes(current.key, key))
        {
            tag = TagView(current.key, current.value);
            return true;
        }
        popFront(tags);
    }

    return false;
}

/**
 * Return whether any tag has exactly matching key bytes.
 *
 * This is the predicate form of `findTag`. It is linear in the number of tags
 * visited, allocates nothing, and does not advance the caller's range cursor.
 */
bool hasTag(R, Q)(
    R tags,
    scope Q[] key)
    @safe nothrow @nogc
if (isSemanticTagRange!R && isTagCodeUnit!Q)
{
    TagView ignored;
    return findTag(tags, key, ignored);
}

/**
 * Return whether any tag exactly matches both key and value.
 *
 * Duplicate keys remain meaningful: a key with one different value does not
 * prevent a later occurrence with the requested value from matching.
 *
 * D `char[]` queries are compared as their existing UTF-8 code units. No
 * normalization, transcoding, case folding, or allocation occurs.
 */
bool tagEquals(R, K, V)(
    R tags,
    scope K[] key,
    scope V[] value)
    @safe nothrow @nogc
if (isSemanticTagRange!R &&
    isTagCodeUnit!K &&
    isTagCodeUnit!V)
{
    while (!empty(tags))
    {
        const current = front(tags);
        if (sameBytes(current.key, key) &&
            sameBytes(current.value, value))
            return true;

        popFront(tags);
    }

    return false;
}

private bool sameBytes(Q)(
    scope const(ubyte)[] stored,
    scope Q[] query)
    @safe pure nothrow @nogc
if (isTagCodeUnit!Q)
{
    if (stored.length != query.length)
        return false;

    foreach (i; 0 .. stored.length)
    {
        if (stored[i] != cast(ubyte)query[i])
            return false;
    }

    return true;
}

unittest
{
    const(ubyte)[] key = ['n', 'a', 'm', 'e'];
    const(ubyte)[] value = ['W', 'i', 'e', 'n'];
    const tag = TagView(key, value);

    assert(tag.key == key);
    assert(tag.value == value);
    static assert(!__traits(hasMember, TagView, "keySid"));
    static assert(!__traits(hasMember, TagView, "valueSid"));
}

unittest
{
    TagView[] tags = [
        TagView(
            cast(const(ubyte)[])"name",
            cast(const(ubyte)[])"Wien"),
        TagView(
            cast(const(ubyte)[])"highway",
            cast(const(ubyte)[])"residential"),
        TagView(
            cast(const(ubyte)[])"name",
            cast(const(ubyte)[])"Vienna"),
    ];

    assert(tags.hasTag("name"));
    assert(tags.hasTag(cast(const(ubyte)[])"highway"));
    assert(!tags.hasTag("building"));

    TagView found;
    assert(tags.findTag("name", found));
    assert(found.value == cast(const(ubyte)[])"Wien");

    assert(tags.tagEquals("name", "Wien"));
    assert(tags.tagEquals("name", "Vienna"));
    assert(!tags.tagEquals("name", "Graz"));

    found = tags[0];
    assert(!tags.findTag("missing", found));
    assert(found.key is null);
    assert(found.value is null);

    // Querying a copied range must not advance the caller's cursor.
    auto cursor = tags;
    assert(cursor.hasTag("highway"));
    assert(cursor.front.key == cast(const(ubyte)[])"name");
}
