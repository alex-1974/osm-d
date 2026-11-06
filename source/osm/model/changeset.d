/**
 * First-class owned OpenStreetMap Changeset semantic values.
 *
 * Changesets are OSM domain objects but are not Node/Way/Relation elements.
 * Their identifiers therefore remain distinct from OsmId semantics. The
 * durable server representation is intentionally separate from the tag-only
 * request payload used by Changeset create/update operations.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-06
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.model.changeset;

import osm.model.owned :
    OwnedBytes,
    OwnedTag;
import osm.view.location : LocationView;

/**
 * Semantic Changeset identifier.
 *
 * This alias documents that the value identifies a Changeset rather than an
 * OSM Node/Way/Relation. Server-backed Changeset IDs are positive.
 */
alias ChangesetId = long;

/** Exact geographic bounds reported by the OSM server for one Changeset. */
struct ChangesetBounds
{
    LocationView minimum;
    LocationView maximum;
}

/**
 * One Changeset-discussion comment returned by the Editing API.
 *
 * Presence is explicit because historical/API response shapes have evolved.
 * Comment text is owned decoded UTF-8 bytes when hasText is true.
 */
struct OwnedChangesetComment
{
    bool hasId;
    long id;

    bool hasDate;
    long dateMilliseconds;

    bool hasUserId;
    long userId;

    bool hasUsername;
    OwnedBytes username;

    bool hasVisibility;
    bool visible;

    bool hasText;
    OwnedBytes text;

    /** Copy this comment. Immutable byte strings are intentionally shared. */
    OwnedChangesetComment deepCopy() const @safe
    {
        return this;
    }
}

/**
 * Durable semantic representation of one OSM Changeset returned by the server.
 *
 * Optional wire fields retain independent presence flags. In particular,
 * bounds may be absent for an empty Changeset and discussion data may be absent
 * simply because it was not requested.
 *
 * Counts are server-reported values. createdCount/modifiedCount/deletedCount
 * correspond to the enhanced Changeset statistics added to the Editing API in
 * 2026 and remain optional for compatibility with older/server-specific
 * response shapes.
 */
struct OwnedChangeset
{
    bool hasId;
    ChangesetId id;

    bool hasOpenState;
    bool open;

    bool hasCreatedAt;
    long createdAtMilliseconds;

    bool hasClosedAt;
    long closedAtMilliseconds;

    bool hasUserId;
    long userId;

    bool hasUsername;
    OwnedBytes username;

    bool hasBounds;
    ChangesetBounds bounds;

    bool hasCommentsCount;
    ulong commentsCount;

    bool hasChangesCount;
    ulong changesCount;

    bool hasCreatedCount;
    ulong createdCount;

    bool hasModifiedCount;
    ulong modifiedCount;

    bool hasDeletedCount;
    ulong deletedCount;

    /** Changeset tags in source order. */
    OwnedTag[] tags;

    /**
     * Whether a discussion element was present in the source response.
     *
     * false means discussion data was not present/not requested. true with an
     * empty comments array means the discussion was present but empty.
     */
    bool hasDiscussion;

    /** Discussion comments in source order when hasDiscussion is true. */
    OwnedChangesetComment[] comments;

    /**
     * Create an independently mutable Changeset snapshot.
     *
     * Immutable byte strings remain safely shared while mutable tag/comment
     * arrays are duplicated.
     */
    OwnedChangeset deepCopy() const @safe
    {
        OwnedChangeset result = this;
        result.tags = tags.dup;
        result.comments = comments.dup;
        return result;
    }
}

/**
 * Tag-only XML payload used for Changeset create and update requests.
 *
 * The OSM Editing API server owns Changeset identity, bounds, timestamps,
 * owner and counters. Keeping this request type separate from OwnedChangeset
 * prevents those server-managed fields from appearing writable.
 *
 * For an update, tags are a complete replacement set: omitted existing tags
 * are removed by the server.
 */
struct ChangesetTagRequest
{
    OwnedTag[] tags;

    /** Create an independently mutable request. */
    ChangesetTagRequest deepCopy() const @safe
    {
        ChangesetTagRequest result;
        result.tags = tags.dup;
        return result;
    }
}

unittest
{
    OwnedChangeset value;
    assert(!value.hasId);
    assert(!value.hasBounds);
    assert(!value.hasDiscussion);

    value.hasId = true;
    value.id = 42;
    value.tags.length = 1;
    value.comments.length = 1;
    value.hasDiscussion = true;

    auto copy = value.deepCopy();
    copy.tags.length = 0;
    copy.comments.length = 0;

    assert(value.tags.length == 1);
    assert(value.comments.length == 1);
    assert(copy.id == 42);
}

unittest
{
    ChangesetTagRequest request;
    request.tags.length = 1;

    auto copy = request.deepCopy();
    copy.tags.length = 0;

    assert(request.tags.length == 1);
}
