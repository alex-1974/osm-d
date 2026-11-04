/**
 * Owned, format-independent OpenStreetMap semantic values.
 *
 * These types are the durable counterpart to the borrowed `osm.view` family.
 * Exact byte strings are copied into immutable GC-managed storage when an input
 * codec materializes them. Element and dataset arrays remain mutable so callers
 * can edit topology, tags and metadata explicitly.
 *
 * Copying one owned struct follows ordinary D dynamic-array semantics: array
 * storage is shared. Immutable byte strings are therefore safely shareable, but
 * mutable element/tag/member arrays alias until the caller replaces or copies
 * them. Use `deepCopy` when an independently mutable dataset snapshot is
 * required.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.model.owned;

import osm.view.element : ElementType, OsmId;
import osm.view.location : LocationView;

/** Immutable owned byte string used for OSM keys, values, usernames and roles. */
alias OwnedBytes = immutable(ubyte)[];

/** One owned OSM tag. */
struct OwnedTag
{
    /// Exact tag-key bytes. No normalization or transcoding is implied.
    OwnedBytes key;
    /// Exact tag-value bytes. No normalization or transcoding is implied.
    OwnedBytes value;
}

/**
 * Owned optional OSM metadata.
 *
 * Every source field has an independent presence flag. `.init` is valid empty
 * metadata and does not invent any protobuf/OSM default value.
 */
struct OwnedMetadata
{
    bool hasVersion;
    int versionNumber;

    bool hasTimestamp;
    long timestampMilliseconds;

    bool hasChangeset;
    long changesetId;

    bool hasUserId;
    int userId;

    bool hasUsername;
    OwnedBytes username;

    bool hasVisibility;
    bool visible;

    /** Return true when no metadata component is present. */
    @property bool empty() const @safe pure nothrow @nogc
    {
        return !hasVersion &&
               !hasTimestamp &&
               !hasChangeset &&
               !hasUserId &&
               !hasUsername &&
               !hasVisibility;
    }
}

/**
 * One owned reference to an OSM Node inside an ordered container such as a Way.
 *
 * `location` is meaningful only when `hasLocation` is true. This preserves
 * the optional LocationsOnWays semantic without exposing PBF parallel columns.
 */
struct OwnedNodeRef
{
    OsmId id;
    bool hasLocation;
    LocationView location;
}

/// v0.1 compatibility alias. Prefer OwnedNodeRef.
alias OwnedWayNode = OwnedNodeRef;

/** One ordered member inside an owned OSM Relation. */
struct OwnedRelationMember
{
    ElementType type;
    OsmId id;
    OwnedBytes role;
}

/**
 * One owned OSM Node.
 *
 * `.init` is a structurally representable value, but id/coordinate validity
 * is a separate validation concern.
 */
struct OwnedNode
{
    OsmId id;
    LocationView location;
    OwnedMetadata metadata;
    OwnedTag[] tags;

    /** Copy this node and its mutable tag array. Immutable string bytes may share. */
    OwnedNode deepCopy() const @safe
    {
        OwnedNode result;
        result.id = id;
        result.location = LocationView(
            location.latitudeNanodegrees,
            location.longitudeNanodegrees);
        result.metadata = copyMetadata(metadata);
        result.tags = copyTags(tags);
        return result;
    }
}

/** One owned OSM Way preserving tag order, node-reference order and duplicates. */
struct OwnedWay
{
    OsmId id;
    OwnedMetadata metadata;
    OwnedTag[] tags;
    OwnedNodeRef[] nodes;

    /** Copy this way and every mutable child array. Immutable strings may share. */
    OwnedWay deepCopy() const @safe
    {
        OwnedWay result;
        result.id = id;
        result.metadata = copyMetadata(metadata);
        result.tags = copyTags(tags);

        result.nodes.length = nodes.length;
        foreach (i, ref const value; nodes)
        {
            result.nodes[i].id = value.id;
            result.nodes[i].hasLocation = value.hasLocation;
            if (value.hasLocation)
            {
                result.nodes[i].location = LocationView(
                    value.location.latitudeNanodegrees,
                    value.location.longitudeNanodegrees);
            }
        }

        return result;
    }
}

/** One owned OSM Relation preserving tag/member order and duplicates. */
struct OwnedRelation
{
    OsmId id;
    OwnedMetadata metadata;
    OwnedTag[] tags;
    OwnedRelationMember[] members;

    /** Copy this relation and every mutable child array. Immutable strings may share. */
    OwnedRelation deepCopy() const @safe
    {
        OwnedRelation result;
        result.id = id;
        result.metadata = copyMetadata(metadata);
        result.tags = copyTags(tags);

        result.members.length = members.length;
        foreach (i, ref const value; members)
        {
            result.members[i].type = value.type;
            result.members[i].id = value.id;
            result.members[i].role = value.role;
        }

        return result;
    }
}

/**
 * Durable in-memory OSM semantic dataset.
 *
 * Elements are grouped by type because cross-type PBF wire ordering is a codec
 * representation detail rather than an OSM semantic contract. Ordering inside
 * each element and inside each tag/reference/member array is preserved exactly.
 *
 * `.init` is a valid empty dataset.
 */
struct OwnedDataset
{
    OwnedNode[] nodes;
    OwnedWay[] ways;
    OwnedRelation[] relations;

    /** Return true when the dataset contains no OSM elements. */
    @property bool empty() const @safe pure nothrow @nogc
    {
        return nodes.length == 0 && ways.length == 0 && relations.length == 0;
    }

    /**
     * Create an independently mutable dataset snapshot.
     *
     * Immutable byte strings are intentionally shared; all arrays that callers
     * may structurally mutate are duplicated.
     */
    OwnedDataset deepCopy() const @safe
    {
        OwnedDataset result;

        result.nodes.length = nodes.length;
        foreach (i, ref const value; nodes)
            result.nodes[i] = value.deepCopy();

        result.ways.length = ways.length;
        foreach (i, ref const value; ways)
            result.ways[i] = value.deepCopy();

        result.relations.length = relations.length;
        foreach (i, ref const value; relations)
            result.relations[i] = value.deepCopy();

        return result;
    }
}

private OwnedMetadata copyMetadata(ref const OwnedMetadata value) @safe
{
    OwnedMetadata result;
    result.hasVersion = value.hasVersion;
    result.versionNumber = value.versionNumber;
    result.hasTimestamp = value.hasTimestamp;
    result.timestampMilliseconds = value.timestampMilliseconds;
    result.hasChangeset = value.hasChangeset;
    result.changesetId = value.changesetId;
    result.hasUserId = value.hasUserId;
    result.userId = value.userId;
    result.hasUsername = value.hasUsername;
    result.username = value.username;
    result.hasVisibility = value.hasVisibility;
    result.visible = value.visible;
    return result;
}

private OwnedTag[] copyTags(scope const(OwnedTag)[] values) @safe
{
    OwnedTag[] result;
    result.length = values.length;
    foreach (i, ref const value; values)
    {
        result[i].key = value.key;
        result[i].value = value.value;
    }
    return result;
}

/** Copy exact borrowed bytes into immutable owned storage. */
OwnedBytes ownBytes(scope const(ubyte)[] bytes) @safe
{
    return bytes.idup;
}

unittest
{
    OwnedDataset dataset;
    assert(dataset.empty);

    OwnedNode node;
    node.id = 1;
    node.location = LocationView(48_000_000_000L, 16_000_000_000L);
    node.tags ~= OwnedTag(ownBytes(cast(const(ubyte)[])"name"),
                          ownBytes(cast(const(ubyte)[])"A"));
    dataset.nodes ~= node;

    auto copy = dataset.deepCopy();
    copy.nodes[0].tags ~= OwnedTag(ownBytes(cast(const(ubyte)[])"x"),
                                   ownBytes(cast(const(ubyte)[])"y"));

    assert(dataset.nodes[0].tags.length == 1);
    assert(copy.nodes[0].tags.length == 2);
    assert(dataset.nodes[0].tags[0].key == copy.nodes[0].tags[0].key);
}
