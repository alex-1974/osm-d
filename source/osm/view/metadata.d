/**
 * Format-independent semantic OpenStreetMap element metadata.
 *
 * MetadataView presents the common OSM metadata carried by PBF Info and
 * DenseInfo without exposing protobuf field names, StringTable IDs, delta
 * encoding, or raw timestamp units.
 *
 * Username bytes remain borrowed from the source codec's backing storage.
 * The view therefore must not outlive the element callback/backing data from
 * which it was obtained. No UTF-8 repair or normalization is performed here.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-01
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.view.metadata;

private enum ubyte
{
    metadataHasVersion    = 1u << 0,
    metadataHasTimestamp  = 1u << 1,
    metadataHasChangeset  = 1u << 2,
    metadataHasUserId     = 1u << 3,
    metadataHasUsername   = 1u << 4,
    metadataHasVisibility = 1u << 5,
}

/**
 * Borrowed semantic metadata for one OSM element.
 *
 * Presence is explicit because every metadata component is optional in the
 * source model. User ID and username remain independently optional: a decoder
 * must not invent one merely because the other is present.
 */
struct MetadataView
{
private:
    long _timestampMilliseconds;
    long _changesetId;
    const(ubyte)[] _username;
    int _versionNumber;
    int _userId;
    ubyte _flags;
    bool _visible;

package(osm):
    /**
     * Construct a semantic metadata view from already validated codec values.
     *
     * This constructor is package-internal so codec implementations can build
     * the common semantic surface without making construction details part of
     * the ordinary consumer API.
     */
    this(
        bool hasVersion,
        int versionNumber,
        bool hasTimestamp,
        long timestampMilliseconds,
        bool hasChangeset,
        long changesetId,
        bool hasUserId,
        int userId,
        bool hasUsername,
        const(ubyte)[] username,
        bool hasVisibility,
        bool visible)
        @safe pure nothrow @nogc
    {
        _versionNumber = versionNumber;
        _timestampMilliseconds = timestampMilliseconds;
        _changesetId = changesetId;
        _userId = userId;
        _username = username;
        _visible = visible;

        if (hasVersion)
            _flags |= metadataHasVersion;
        if (hasTimestamp)
            _flags |= metadataHasTimestamp;
        if (hasChangeset)
            _flags |= metadataHasChangeset;
        if (hasUserId)
            _flags |= metadataHasUserId;
        if (hasUsername)
            _flags |= metadataHasUsername;
        if (hasVisibility)
            _flags |= metadataHasVisibility;
    }

public:
    /** Whether an OSM element version is present. */
    pragma(inline, true)
    @property bool hasVersion() const @safe pure nothrow @nogc
    {
        return (_flags & metadataHasVersion) != 0;
    }

    /**
     * OSM element version number.
     *
     * Read this value only when hasVersion is true.
     */
    pragma(inline, true)
    @property int versionNumber() const @safe pure nothrow @nogc
    {
        return _versionNumber;
    }

    /** Whether a timestamp is present. */
    pragma(inline, true)
    @property bool hasTimestamp() const @safe pure nothrow @nogc
    {
        return (_flags & metadataHasTimestamp) != 0;
    }

    /**
     * Exact timestamp in milliseconds since the Unix epoch.
     *
     * Read this value only when hasTimestamp is true.
     */
    pragma(inline, true)
    @property long timestampMilliseconds() const @safe pure nothrow @nogc
    {
        return _timestampMilliseconds;
    }

    /** Whether a changeset identifier is present. */
    pragma(inline, true)
    @property bool hasChangeset() const @safe pure nothrow @nogc
    {
        return (_flags & metadataHasChangeset) != 0;
    }

    /**
     * OSM changeset identifier.
     *
     * A changeset ID is not an OsmId because it does not identify a node, way,
     * or relation.
     */
    pragma(inline, true)
    @property long changesetId() const @safe pure nothrow @nogc
    {
        return _changesetId;
    }

    /** Whether a numeric OSM user identifier is present. */
    pragma(inline, true)
    @property bool hasUserId() const @safe pure nothrow @nogc
    {
        return (_flags & metadataHasUserId) != 0;
    }

    /**
     * Numeric OSM user identifier.
     *
     * Read this value only when hasUserId is true.
     */
    pragma(inline, true)
    @property int userId() const @safe pure nothrow @nogc
    {
        return _userId;
    }

    /** Whether a username is present. */
    pragma(inline, true)
    @property bool hasUsername() const @safe pure nothrow @nogc
    {
        return (_flags & metadataHasUsername) != 0;
    }

    /**
     * Borrowed raw username bytes.
     *
     * The bytes use the source codec's string representation. This slice does
     * not imply UTF-8 validation, repair, normalization, or ownership.
     */
    pragma(inline, true)
    @property const(ubyte)[] username() const @safe pure nothrow @nogc
    {
        return _username;
    }

    /** Whether visibility/deletion state is explicitly present. */
    pragma(inline, true)
    @property bool hasVisibility() const @safe pure nothrow @nogc
    {
        return (_flags & metadataHasVisibility) != 0;
    }

    /**
     * OSM visibility value.
     *
     * Read this value only when hasVisibility is true.
     */
    pragma(inline, true)
    @property bool visible() const @safe pure nothrow @nogc
    {
        return _visible;
    }

    /** Whether no metadata component is present. */
    pragma(inline, true)
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _flags == 0;
    }
}

unittest
{
    const(ubyte)[] username = ['a', 'l', 'e', 'x'];

    const metadata = MetadataView(
        true, 7,
        true, 1_700_000_000_123L,
        true, 42,
        true, 9,
        true, username,
        true, false);

    assert(!metadata.empty);
    assert(metadata.hasVersion && metadata.versionNumber == 7);
    assert(metadata.hasTimestamp &&
        metadata.timestampMilliseconds == 1_700_000_000_123L);
    assert(metadata.hasChangeset && metadata.changesetId == 42);
    assert(metadata.hasUserId && metadata.userId == 9);
    assert(metadata.hasUsername && metadata.username == username);
    assert(metadata.hasVisibility && !metadata.visible);
}

unittest
{
    // User ID and username are deliberately independent semantic presences.
    const(ubyte)[] username = ['u'];

    const idOnly = MetadataView(
        false, 0,
        false, 0,
        false, 0,
        true, 5,
        false, null,
        false, false);

    assert(idOnly.hasUserId && idOnly.userId == 5);
    assert(!idOnly.hasUsername);
    assert(idOnly.username.length == 0);

    const nameOnly = MetadataView(
        false, 0,
        false, 0,
        false, 0,
        false, 0,
        true, username,
        false, false);

    assert(!nameOnly.hasUserId);
    assert(nameOnly.hasUsername && nameOnly.username == username);
}

unittest
{
    const metadata = MetadataView.init;
    assert(metadata.empty);
    assert(!metadata.hasVersion);
    assert(!metadata.hasTimestamp);
    assert(!metadata.hasChangeset);
    assert(!metadata.hasUserId);
    assert(!metadata.hasUsername);
    assert(!metadata.hasVisibility);
}
