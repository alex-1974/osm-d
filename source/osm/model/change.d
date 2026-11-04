/**
 * Format-independent owned OpenStreetMap change operations.
 *
 * OSM edit operations act on whole element states rather than on XML nodes or
 * individual tags. This module therefore models create/modify/delete semantics
 * independently of OSM XML and osmChange syntax.
 *
 * A create or modify entry is complete. A delete entry may either carry the
 * complete prior element or an identity-only deletion stub, because the OSM
 * Editing API accepts minimal delete objects containing identity and required
 * upload metadata. Visibility remains ordinary element metadata and is never
 * used to infer the operation.
 *
 * Array fields follow ordinary D dynamic-array copy semantics. Use deepCopy
 * when an independently mutable change sequence is required.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.model.change;

import osm.model.owned :
    OwnedMetadata,
    OwnedNode,
    OwnedRelation,
    OwnedRelationMember,
    OwnedTag,
    OwnedWay,
    OwnedWayNode,
    ownBytes;
import osm.view.element : ElementType, OsmId;
import osm.view.location : LocationView;

/** Whole-object operation represented by one change entry. */
enum ChangeAction : ubyte
{
    create,
    modify,
    deleteObject,
}

/**
 * Whether the entry contains a complete element state or only delete identity.
 *
 * identityOnly is valid only for deleteObject. create and modify always require
 * complete element state before they are uploadable.
 */
enum ChangeObjectState : ubyte
{
    identityOnly,
    complete,
}

/**
 * One format-independent owned OSM change entry.
 *
 * Fields common to every element are stored once. The payload selected by type
 * is:
 *
 * - node: location + tags;
 * - way: wayNodes + tags;
 * - relation: relationMembers + tags.
 *
 * Unused payload arrays must be empty for a structurally valid entry.
 * deleteIfUnused represents the Editing API/osmChange deletion policy
 * explicitly. It is meaningful only for deleteObject and is never implied.
 *
 * .init is safe to destroy and assign, but it is not a valid change operation:
 * it describes a create action with identity-only content.
 */
struct OwnedChangeEntry
{
    /// Requested whole-object operation.
    ChangeAction action;

    /// OSM element kind.
    ElementType type;

    /// Whether full object content is present.
    ChangeObjectState objectState;

    /// Explicit conditional-delete policy. Meaningful only for deleteObject.
    bool deleteIfUnused;

    /// Element identifier. Negative local/create IDs are preserved.
    OsmId id;

    /// Optional OSM element metadata with independent presence flags.
    OwnedMetadata metadata;

    /**
     * Node location when type is node and objectState is complete.
     *
     * This field is ignored for ways, relations, and identity-only deletes.
     */
    LocationView location;

    /// Ordered tags, preserving input order and duplicates.
    OwnedTag[] tags;

    /// Ordered Way node references when type is way.
    OwnedWayNode[] wayNodes;

    /// Ordered Relation members when type is relation.
    OwnedRelationMember[] relationMembers;

    /** Construct a complete Node change without copying child-array storage. */
    static OwnedChangeEntry fromNode(ChangeAction action, OwnedNode value) @safe
    {
        OwnedChangeEntry result;
        result.action = action;
        result.type = ElementType.node;
        result.objectState = ChangeObjectState.complete;
        result.id = value.id;
        result.metadata = value.metadata;
        result.location = value.location;
        result.tags = value.tags;
        return result;
    }

    /** Construct a complete Way change without copying child-array storage. */
    static OwnedChangeEntry fromWay(ChangeAction action, OwnedWay value) @safe
    {
        OwnedChangeEntry result;
        result.action = action;
        result.type = ElementType.way;
        result.objectState = ChangeObjectState.complete;
        result.id = value.id;
        result.metadata = value.metadata;
        result.tags = value.tags;
        result.wayNodes = value.nodes;
        return result;
    }

    /** Construct a complete Relation change without copying child-array storage. */
    static OwnedChangeEntry fromRelation(ChangeAction action, OwnedRelation value) @safe
    {
        OwnedChangeEntry result;
        result.action = action;
        result.type = ElementType.relation;
        result.objectState = ChangeObjectState.complete;
        result.id = value.id;
        result.metadata = value.metadata;
        result.tags = value.tags;
        result.relationMembers = value.members;
        return result;
    }

    /**
     * Construct an identity-only deletion.
     *
     * Params:
     *   type = OSM element kind to delete.
     *   id = Element identifier.
     *   metadata = Metadata required or retained for the deletion, typically
     *              including version and changeset for API upload.
     *   ifUnused = Whether the delete is conditional on the object being unused.
     */
    static OwnedChangeEntry deletion(
        ElementType type,
        OsmId id,
        OwnedMetadata metadata = OwnedMetadata.init,
        bool ifUnused = false) @safe
    {
        OwnedChangeEntry result;
        result.action = ChangeAction.deleteObject;
        result.type = type;
        result.objectState = ChangeObjectState.identityOnly;
        result.deleteIfUnused = ifUnused;
        result.id = id;
        result.metadata = metadata;
        return result;
    }

    /** Whether this entry carries a complete element state. */
    @property bool complete() const @safe pure nothrow @nogc
    {
        return objectState == ChangeObjectState.complete;
    }

    /**
     * Check only the representation-shape invariants of this entry.
     *
     * This is deliberately weaker than upload validation. Version, changeset,
     * coordinate, reference, duplicate-tag, placeholder and dependency rules
     * belong to the complete-object/API validation layer.
     */
    @property bool shapeValid() const @safe pure nothrow @nogc
    {
        if (deleteIfUnused && action != ChangeAction.deleteObject)
            return false;

        if (objectState == ChangeObjectState.identityOnly)
        {
            return action == ChangeAction.deleteObject &&
                   tags.length == 0 &&
                   wayNodes.length == 0 &&
                   relationMembers.length == 0;
        }

        final switch (type)
        {
            case ElementType.node:
                return wayNodes.length == 0 && relationMembers.length == 0;
            case ElementType.way:
                return relationMembers.length == 0;
            case ElementType.relation:
                return wayNodes.length == 0;
        }
    }

    /**
     * Create an independently mutable copy.
     *
     * Immutable key/value/role/username byte strings remain safely shared.
     */
    OwnedChangeEntry deepCopy() const @safe
    {
        OwnedChangeEntry result;
        result.action = action;
        result.type = type;
        result.objectState = objectState;
        result.deleteIfUnused = deleteIfUnused;
        result.id = id;
        result.metadata = metadata;
        result.location = LocationView(
            location.latitudeNanodegrees,
            location.longitudeNanodegrees);

        result.tags.length = tags.length;
        foreach (i, ref const value; tags)
            result.tags[i] = value;

        result.wayNodes.length = wayNodes.length;
        foreach (i, ref const value; wayNodes)
        {
            result.wayNodes[i].id = value.id;
            result.wayNodes[i].hasLocation = value.hasLocation;
            if (value.hasLocation)
            {
                result.wayNodes[i].location = LocationView(
                    value.location.latitudeNanodegrees,
                    value.location.longitudeNanodegrees);
            }
        }

        result.relationMembers.length = relationMembers.length;
        foreach (i, ref const value; relationMembers)
            result.relationMembers[i] = value;

        return result;
    }
}

/**
 * Ordered owned sequence of OSM change operations.
 *
 * Entry order is semantic input order. A codec may encode consecutive entries
 * into format-level action groups, but it must not silently reorder the
 * sequence. Dependency-safe upload ordering is a separate explicit operation.
 */
struct OwnedChangeSequence
{
    OwnedChangeEntry[] entries;

    /** Return true when no operations are present. */
    @property bool empty() const @safe pure nothrow @nogc
    {
        return entries.length == 0;
    }

    /**
     * Assign one explicit changeset ID to every operation.
     *
     * This is an upload-preparation operation, not an inferred default. A
     * non-positive ID is rejected without modifying the sequence.
     */
    bool setChangeset(long changesetId) @safe nothrow @nogc
    {
        if (changesetId <= 0)
            return false;

        foreach (ref entry; entries)
        {
            entry.metadata.hasChangeset = true;
            entry.metadata.changesetId = changesetId;
        }
        return true;
    }

    /** Create an independently mutable sequence. */
    OwnedChangeSequence deepCopy() const @safe
    {
        OwnedChangeSequence result;
        result.entries.length = entries.length;
        foreach (i, ref const value; entries)
            result.entries[i] = value.deepCopy();
        return result;
    }
}

/**
 * Request-context interpretation of one OSM API diff-result entry.
 *
 * Raw diffResult shape alone is not sufficient to identify every operation:
 * conditional delete-if-unused may return new ID/version when the object was
 * retained, and one placeholder may legitimately appear in more than one
 * result entry in a general diff upload.
 */
enum UploadResultEffect : ubyte
{
    none,
    created,
    modified,
    deleted,
    deleteRetained,
    alreadyDeleted,
}

/**
 * One raw authoritative result entry returned after a successful OSM diff upload.
 *
 * The type is format-neutral: XML parsing and HTTP transport are intentionally
 * outside this model. OSM API 0.6 diffResult fields are preserved without
 * pretending that field shape always identifies the originating action:
 *
 * - create normally has old ID plus positive new ID/version;
 * - modify normally has old ID plus new ID/version;
 * - successful delete normally has only old ID;
 * - delete-if-unused may instead return old ID plus current new ID/version when
 *   the requested deletion was not performed;
 * - placeholder reuse can repeat the same type+oldId in a general result.
 *
 * Use effectFor with the matching uploaded request entry when action/effect
 * semantics matter. .init is invalid because oldId is zero.
 */
struct UploadResultEntry
{
    ElementType type;
    OsmId oldId;

    bool hasNewId;
    OsmId newId;

    bool hasNewVersion;
    int newVersion;

    /** Construct a create-shaped acknowledgement. */
    static UploadResultEntry created(
        ElementType type,
        OsmId oldId,
        OsmId newId,
        int newVersion) @safe pure nothrow @nogc
    {
        UploadResultEntry result;
        result.type = type;
        result.oldId = oldId;
        result.hasNewId = true;
        result.newId = newId;
        result.hasNewVersion = true;
        result.newVersion = newVersion;
        return result;
    }

    /** Construct a modify-shaped acknowledgement. */
    static UploadResultEntry modified(
        ElementType type,
        OsmId id,
        int newVersion) @safe pure nothrow @nogc
    {
        return created(type, id, id, newVersion);
    }

    /** Construct a bare delete-shaped acknowledgement. */
    static UploadResultEntry deleted(
        ElementType type,
        OsmId id) @safe pure nothrow @nogc
    {
        UploadResultEntry result;
        result.type = type;
        result.oldId = id;
        return result;
    }

    /** Whether the raw fields have a representable OSM API diff-result shape. */
    @property bool shapeValid() const @safe pure nothrow @nogc
    {
        if (oldId == 0 || hasNewId != hasNewVersion)
            return false;

        if (!hasNewId)
            return true;

        if (newId <= 0 || newVersion <= 0)
            return false;

        if (oldId < 0)
            return true;

        return newId == oldId;
    }

    /**
     * Interpret this result against the exact uploaded request entry.
     *
     * This is the authoritative operation/effect classifier. In particular,
     * an oldId/newId/newVersion shape can mean modify, retained
     * delete-if-unused, or already-deleted conditional delete depending on the
     * request context.
     *
     * Returns false when the raw result cannot acknowledge uploaded.
     */
    bool effectFor(
        scope ref const OwnedChangeEntry uploaded,
        out UploadResultEffect effect) const
        @safe pure nothrow @nogc
    {
        effect = UploadResultEffect.none;

        if (!shapeValid ||
            !uploaded.shapeValid ||
            type != uploaded.type ||
            oldId != uploaded.id)
        {
            return false;
        }

        final switch (uploaded.action)
        {
            case ChangeAction.create:
                if (uploaded.id >= 0 || !hasNewId)
                    return false;
                effect = UploadResultEffect.created;
                return true;

            case ChangeAction.modify:
                if (!hasNewId)
                    return false;
                effect = UploadResultEffect.modified;
                return true;

            case ChangeAction.deleteObject:
                if (!hasNewId)
                {
                    effect = UploadResultEffect.deleted;
                    return true;
                }

                if (!uploaded.deleteIfUnused ||
                    !uploaded.metadata.hasVersion ||
                    uploaded.metadata.versionNumber <= 0 ||
                    newVersion < uploaded.metadata.versionNumber)
                {
                    return false;
                }

                effect = newVersion == uploaded.metadata.versionNumber
                    ? UploadResultEffect.deleteRetained
                    : UploadResultEffect.alreadyDeleted;
                return true;
        }
    }

}

/**
 * Authoritative result of one successful diff-upload request.
 *
 * Entry order is retained from the source response. A general OSM diff upload
 * may legitimately repeat type+oldId when a negative placeholder is reused,
 * so consumers must correlate entries with the uploaded request rather than
 * assuming type+oldId is globally unique.
 */
struct UploadResult
{
    UploadResultEntry[] entries;

    @property bool empty() const @safe pure nothrow @nogc
    {
        return entries.length == 0;
    }
}

unittest
{
    OwnedNode node;
    node.id = -1;
    node.location = LocationView(48_208_174_300L, 16_373_818_900L);
    node.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"amenity"),
        ownBytes(cast(const(ubyte)[])"bench"));

    auto created = OwnedChangeEntry.fromNode(ChangeAction.create, node);
    assert(created.shapeValid);
    assert(created.complete);
    assert(created.type == ElementType.node);
    assert(created.id == -1);
    assert(created.tags.length == 1);
}

unittest
{
    OwnedMetadata metadata;
    metadata.hasVersion = true;
    metadata.versionNumber = 7;
    metadata.hasChangeset = true;
    metadata.changesetId = 42;

    auto deleted = OwnedChangeEntry.deletion(
        ElementType.way, 123, metadata, true);

    assert(deleted.shapeValid);
    assert(!deleted.complete);
    assert(deleted.action == ChangeAction.deleteObject);
    assert(deleted.deleteIfUnused);
    assert(deleted.metadata.versionNumber == 7);
}

unittest
{
    OwnedWay way;
    way.id = 5;
    way.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"highway"),
        ownBytes(cast(const(ubyte)[])"service"));

    OwnedChangeSequence sequence;
    sequence.entries ~= OwnedChangeEntry.fromWay(ChangeAction.modify, way);

    auto copy = sequence.deepCopy();
    copy.entries[0].tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"A"));

    assert(sequence.entries[0].tags.length == 1);
    assert(copy.entries[0].tags.length == 2);
}

unittest
{
    OwnedChangeSequence changes;
    changes.entries ~= OwnedChangeEntry.deletion(ElementType.node, 1);
    assert(changes.setChangeset(42));
    assert(changes.entries[0].metadata.hasChangeset);
    assert(changes.entries[0].metadata.changesetId == 42);
    assert(!changes.setChangeset(0));
    assert(changes.entries[0].metadata.changesetId == 42);
}

unittest
{
    const created = UploadResultEntry.created(
        ElementType.node, -1, 1001, 1);
    assert(created.shapeValid);
    assert(created.action == ChangeAction.create);

    const modified = UploadResultEntry.modified(
        ElementType.way, 22, 8);
    assert(modified.shapeValid);
    assert(modified.action == ChangeAction.modify);

    const deleted = UploadResultEntry.deleted(
        ElementType.relation, 33);
    assert(deleted.shapeValid);
    assert(deleted.action == ChangeAction.deleteObject);

    assert(!UploadResultEntry.init.shapeValid);
}

unittest // v0.2.1: diffResult interpretation requires request context
{
    foreach (type; [ElementType.node, ElementType.way, ElementType.relation])
    {
        OwnedMetadata metadata;
        metadata.hasVersion = true;
        metadata.versionNumber = 7;

        const conditional = OwnedChangeEntry.deletion(type, 42, metadata, true);

        const retained = UploadResultEntry.modified(type, 42, 7);
        UploadResultEffect effect;
        assert(retained.effectFor(conditional, effect));
        assert(effect == UploadResultEffect.deleteRetained);

        const alreadyDeleted = UploadResultEntry.modified(type, 42, 8);
        assert(alreadyDeleted.effectFor(conditional, effect));
        assert(effect == UploadResultEffect.alreadyDeleted);

        const unconditional = OwnedChangeEntry.deletion(type, 42, metadata, false);
        assert(!retained.effectFor(unconditional, effect));
        assert(effect == UploadResultEffect.none);

        const deleted = UploadResultEntry.deleted(type, 42);
        assert(deleted.effectFor(conditional, effect));
        assert(effect == UploadResultEffect.deleted);
    }

    const placeholderDelete = UploadResultEntry.deleted(ElementType.node, -1);
    assert(placeholderDelete.shapeValid);

    UploadResult repeated;
    repeated.entries ~= UploadResultEntry.created(ElementType.node, -1, 101, 1);
    repeated.entries ~= UploadResultEntry.created(ElementType.node, -1, 101, 2);
    repeated.entries ~= placeholderDelete;
    assert(repeated.entries.length == 3);
}
