/**
 * Format-independent borrowed OpenStreetMap tags.
 *
 * A tag is exposed as its exact key and value byte sequences. Codec-specific
 * lookup state such as OSMPBF StringTable IDs does not cross this semantic
 * boundary. No normalization, repair, transcoding, or allocation is performed.
 *
 * Both byte slices are borrowed and must not outlive the backing storage owned
 * by the reader or representation that produced the view.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-01
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.view.tag;

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
