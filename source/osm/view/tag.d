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
 * The lookup helpers in this module accept osm-d semantic tag cursors whose
 * front value exposes exact byte `key` and `value` slices. This deliberately
 * includes both Phobos-compatible store InputRanges and the tighter
 * callback-scoped PBF cursors. Helpers consume only a copy of the supplied
 * cursor, so querying a borrowed tag range does not advance the caller.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-01
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.view.tag;

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

/**
 * Result of an exact tag-key lookup.
 *
 * `found == false` means that no matching key exists and `tag` is
 * `TagView.init`. When `found` is true, `tag` borrows the same backing
 * storage as the queried tag cursor.
 */
struct TagLookupResult
{
    bool found;
    TagView tag;
}

private enum bool isTagCodeUnit(T) =
    is(Unqual!T == ubyte) || is(Unqual!T == char);

private enum bool isSemanticTagRange(R) =
    __traits(compiles, (R range)
    {
        bool done = range.empty;
        auto tag = range.front;
        const(ubyte)[] key = tag.key;
        const(ubyte)[] value = tag.value;
        range.popFront();
    });

/**
 * Find the first tag with exactly matching key bytes.
 *
 * The query may be supplied as `ubyte[]` or D `char[]`. A D string is
 * compared as its existing UTF-8 code units; no decoding, normalization,
 * transcoding, case folding, or allocation occurs.
 *
 * Duplicate keys are preserved by the underlying cursor. This function returns
 * the first matching occurrence in cursor order.
 *
 * Params:
 *   tags = Borrowed semantic tag range/cursor exposing `empty`, `front`
 *     and `popFront`. The cursor is consumed by value; the caller's cursor is
 *     not advanced.
 *   key = Exact key bytes/code units to match.
 *
 * Returns:
 *   A `TagLookupResult`. Its tag borrows the same backing storage as
 *   `tags` when `found` is true.
 *
 * Safety:
 *   No allocation or normalization is performed. The `return scope`
 *   parameter ties a successful borrowed result to the supplied cursor's
 *   lifetime under DIP1000.
 */
TagLookupResult findTag(R, Q)(
    return scope R tags,
    scope Q[] key)
    @safe nothrow @nogc
if (isSemanticTagRange!R && isTagCodeUnit!Q)
{
    while (!tags.empty)
    {
        if (sameBytes(tags.front.key, key))
        {
            return TagLookupResult(
                true,
                TagView(tags.front.key, tags.front.value));
        }
        tags.popFront();
    }

    return TagLookupResult.init;
}

/**
 * Return whether any tag has exactly matching key bytes.
 *
 * This is linear in the number of tags visited, allocates nothing, and does not
 * advance the caller's cursor.
 */
bool hasTag(R, Q)(
    scope R tags,
    scope Q[] key)
    @safe nothrow @nogc
if (isSemanticTagRange!R && isTagCodeUnit!Q)
{
    while (!tags.empty)
    {
        if (sameBytes(tags.front.key, key))
            return true;
        tags.popFront();
    }
    return false;
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
    scope R tags,
    scope K[] key,
    scope V[] value)
    @safe nothrow @nogc
if (isSemanticTagRange!R &&
    isTagCodeUnit!K &&
    isTagCodeUnit!V)
{
    while (!tags.empty)
    {
        if (sameBytes(tags.front.key, key) &&
            sameBytes(tags.front.value, value))
            return true;

        tags.popFront();
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
    struct TestTagCursor
    {
        TagView[] values;
        size_t position;

        @property bool empty() const @safe pure nothrow @nogc
        {
            return position >= values.length;
        }

        @property TagView front() const @safe pure nothrow @nogc
        in (!empty)
        {
            return values[position];
        }

        void popFront() @safe pure nothrow @nogc
        in (!empty)
        {
            ++position;
        }
    }

    TagView[] values = [
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
    auto tags = TestTagCursor(values);

    assert(tags.hasTag("name"));
    assert(tags.hasTag(cast(const(ubyte)[])"highway"));
    assert(!tags.hasTag("building"));

    auto found = tags.findTag("name");
    assert(found.found);
    assert(found.tag.value == cast(const(ubyte)[])"Wien");

    assert(tags.tagEquals("name", "Wien"));
    assert(tags.tagEquals("name", "Vienna"));
    assert(!tags.tagEquals("name", "Graz"));

    found = tags.findTag("missing");
    assert(!found.found);
    assert(found.tag.key is null);
    assert(found.tag.value is null);

    // Querying a copied cursor must not advance the caller's cursor.
    assert(tags.hasTag("highway"));
    assert(tags.front.key == cast(const(ubyte)[])"name");
}
