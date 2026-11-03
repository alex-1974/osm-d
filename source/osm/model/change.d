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
