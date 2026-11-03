/**
 * Deterministic upload-readiness validation for format-neutral OSM changes.
 *
 * Parsing and upload validation are intentionally separate. A syntactically
 * representable osmChange document can still be unsafe or invalid to upload.
 * This module checks the current shared OSM edit contract without repairing,
 * reordering, deduplicating or otherwise mutating the change sequence.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.validation.change;

import osm.model.change :
    ChangeAction,
    ChangeObjectState,
    OwnedChangeEntry,
    OwnedChangeSequence;
import osm.model.owned :
    OwnedTag;
import osm.validation.capability :
    CapabilityProfile;
import osm.view.element :
    ElementType,
    OsmId;

/** First deterministic upload-readiness failure. */
enum UploadValidationError : ubyte
{
    none,
    changesetElementLimitExceeded,
    invalidEntryShape,
    incompleteObject,
    zeroElementId,
    createIdMustBeNegative,
    existingIdMustBePositive,
    duplicateCreatePlaceholder,
    missingChangeset,
    invalidChangeset,
    missingVersion,
    invalidVersion,
    invalidNodeLocation,
    nonCanonicalCoordinatePrecision,
    invalidUtf8,
    emptyTagKey,
    tagTooLong,
    duplicateTagKey,
    wayNodeLimitExceeded,
    relationMemberLimitExceeded,
    unrepresentableWayNodeLocation,
    zeroReference,
    unresolvedLocalReference,
}

/**
 * Diagnostic for the first invalid change.
 *
 * childIndex identifies a tag/reference/member when hasChild is true.
 * referenceType/referenceId are populated for unresolved/zero references.
 */
struct UploadValidationIssue
{
    UploadValidationError error = UploadValidationError.none;

    size_t entryIndex;
    ChangeAction action;
    ElementType elementType;
    OsmId elementId;
    bool hasEntry;

    size_t childIndex;
    bool hasChild;

    ElementType referenceType;
    OsmId referenceId;
    bool hasReference;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == UploadValidationError.none;
    }
}

/**
 * Validate an ordered change sequence for OSM API-style upload.
 *
 * Rules enforced independently of target-server capability values:
 *
 * - create/modify objects are complete;
 * - element ID zero is rejected;
 * - create IDs are negative and unique per element namespace;
 * - modify/delete target positive established IDs;
 * - every entry carries a positive changeset ID;
 * - modify/delete carry a positive authoritative version;
 * - Node coordinates are in world bounds and losslessly representable at
 *   1e-7 degree (100 nanodegrees);
 * - tag UTF-8/key/value length and duplicate-key rules;
 * - Way LocationsOnWays payload is rejected because osmChange XML cannot
 *   represent it;
 * - zero references are rejected;
 * - every negative/local reference resolves to a preceding create entry of the
 *   same element type, so forward references and placeholder cycles fail.
 *
 * Optional CapabilityProfile limits are applied when nonzero.
 *
 * The function does not reorder or repair input.
 */
bool validateUploadChanges(
    ref const OwnedChangeSequence changes,
    CapabilityProfile capabilities,
    out UploadValidationIssue issue)
    @safe
{
    issue = UploadValidationIssue.init;

    if (capabilities.maximumChangesetElements != 0 &&
        changes.entries.length > capabilities.maximumChangesetElements)
    {
        issue.error = UploadValidationError.changesetElementLimitExceeded;
        return false;
    }

    bool[Identity] created;

    foreach (entryIndex, ref const entry; changes.entries)
    {
        setEntry(issue, entryIndex, entry);

        if (!entry.shapeValid)
            return fail(issue, UploadValidationError.invalidEntryShape);

        if ((entry.action == ChangeAction.create ||
             entry.action == ChangeAction.modify) &&
            entry.objectState != ChangeObjectState.complete)
        {
            return fail(issue, UploadValidationError.incompleteObject);
        }

        if (entry.id == 0)
            return fail(issue, UploadValidationError.zeroElementId);

        if (entry.action == ChangeAction.create)
        {
            if (entry.id >= 0)
                return fail(issue, UploadValidationError.createIdMustBeNegative);

            const identity = Identity(entry.type, entry.id);
            if (identity in created)
                return fail(
                    issue,
                    UploadValidationError.duplicateCreatePlaceholder);
        }
        else if (entry.id <= 0)
        {
            return fail(issue, UploadValidationError.existingIdMustBePositive);
        }

        if (!entry.metadata.hasChangeset)
            return fail(issue, UploadValidationError.missingChangeset);
        if (entry.metadata.changesetId <= 0)
            return fail(issue, UploadValidationError.invalidChangeset);

        if (entry.action == ChangeAction.modify ||
            entry.action == ChangeAction.deleteObject)
        {
            if (!entry.metadata.hasVersion)
                return fail(issue, UploadValidationError.missingVersion);
            if (entry.metadata.versionNumber <= 0)
                return fail(issue, UploadValidationError.invalidVersion);
        }

        if (entry.objectState == ChangeObjectState.complete)
        {
            if (!validateCompleteEntry(
                    entry,
                    capabilities,
                    created,
                    issue))
            {
                return false;
            }
        }

        if (entry.action == ChangeAction.create)
            created[Identity(entry.type, entry.id)] = true;
    }

    issue = UploadValidationIssue.init;
    return true;
}

private:

enum size_t maximumTagCharacters = 255;
enum long canonicalNanodegreeQuantum = 100;

struct Identity
{
    ElementType type;
    OsmId id;
}

void setEntry(
    ref UploadValidationIssue issue,
    size_t index,
    ref const OwnedChangeEntry entry)
    @safe pure nothrow @nogc
{
    issue = UploadValidationIssue.init;
    issue.entryIndex = index;
    issue.action = entry.action;
    issue.elementType = entry.type;
    issue.elementId = entry.id;
    issue.hasEntry = true;
}

bool fail(
    ref UploadValidationIssue issue,
    UploadValidationError error)
    @safe pure nothrow @nogc
{
    issue.error = error;
    return false;
}

bool failChild(
    ref UploadValidationIssue issue,
    UploadValidationError error,
    size_t childIndex)
    @safe pure nothrow @nogc
{
    issue.error = error;
    issue.childIndex = childIndex;
    issue.hasChild = true;
    return false;
}

bool failReference(
    ref UploadValidationIssue issue,
    UploadValidationError error,
    size_t childIndex,
    ElementType type,
    OsmId id)
    @safe pure nothrow @nogc
{
    issue.error = error;
    issue.childIndex = childIndex;
    issue.hasChild = true;
    issue.referenceType = type;
    issue.referenceId = id;
    issue.hasReference = true;
    return false;
}

bool validateCompleteEntry(
    ref const OwnedChangeEntry entry,
    CapabilityProfile capabilities,
    ref bool[Identity] created,
    ref UploadValidationIssue issue)
    @safe
{
    if (!validateTags(entry.tags, issue))
        return false;

    final switch (entry.type)
    {
        case ElementType.node:
            return validateNode(entry, issue);

        case ElementType.way:
            if (capabilities.maximumWayNodes != 0 &&
                entry.wayNodes.length > capabilities.maximumWayNodes)
            {
                return fail(
                    issue,
                    UploadValidationError.wayNodeLimitExceeded);
            }

            foreach (i, ref const nodeRef; entry.wayNodes)
            {
                if (nodeRef.hasLocation)
                {
                    return failChild(
                        issue,
                        UploadValidationError.unrepresentableWayNodeLocation,
                        i);
                }

                if (!validateReference(
                        ElementType.node,
                        nodeRef.id,
                        i,
                        created,
                        issue))
                {
                    return false;
                }
            }
            return true;

        case ElementType.relation:
            if (capabilities.maximumRelationMembers != 0 &&
                entry.relationMembers.length >
                    capabilities.maximumRelationMembers)
            {
                return fail(
                    issue,
                    UploadValidationError.relationMemberLimitExceeded);
            }

            foreach (i, ref const member; entry.relationMembers)
            {
                size_t roleCount;
                if (!utf8ScalarCount(member.role, roleCount))
                {
                    return failChild(
                        issue,
                        UploadValidationError.invalidUtf8,
                        i);
                }

                if (!validateReference(
                        member.type,
                        member.id,
                        i,
                        created,
                        issue))
                {
                    return false;
                }
            }
            return true;
    }
}

bool validateNode(
    ref const OwnedChangeEntry entry,
    ref UploadValidationIssue issue)
    @safe pure nothrow @nogc
{
    const lat = entry.location.latitudeNanodegrees;
    const lon = entry.location.longitudeNanodegrees;

    if (lat < -90_000_000_000L ||
        lat >  90_000_000_000L ||
        lon < -180_000_000_000L ||
        lon >  180_000_000_000L)
    {
        return fail(issue, UploadValidationError.invalidNodeLocation);
    }

    if (lat % canonicalNanodegreeQuantum != 0 ||
        lon % canonicalNanodegreeQuantum != 0)
    {
        return fail(
            issue,
            UploadValidationError.nonCanonicalCoordinatePrecision);
    }

    return true;
}

bool validateTags(
    scope const(OwnedTag)[] tags,
    ref UploadValidationIssue issue)
    @safe pure nothrow @nogc
{
    foreach (i, ref const tag; tags)
    {
        size_t keyCharacters;
        size_t valueCharacters;

        if (!utf8ScalarCount(tag.key, keyCharacters) ||
            !utf8ScalarCount(tag.value, valueCharacters))
        {
            return failChild(
                issue,
                UploadValidationError.invalidUtf8,
                i);
        }

        if (keyCharacters == 0)
            return failChild(issue, UploadValidationError.emptyTagKey, i);

        if (keyCharacters > maximumTagCharacters ||
            valueCharacters > maximumTagCharacters)
        {
            return failChild(issue, UploadValidationError.tagTooLong, i);
        }

        foreach (j; 0 .. i)
        {
            if (tags[j].key == tag.key)
            {
                return failChild(
                    issue,
                    UploadValidationError.duplicateTagKey,
                    i);
            }
        }
    }

    return true;
}

bool validateReference(
    ElementType type,
    OsmId id,
    size_t childIndex,
    ref bool[Identity] created,
    ref UploadValidationIssue issue)
    @safe
{
    if (id == 0)
    {
        return failReference(
            issue,
            UploadValidationError.zeroReference,
            childIndex,
            type,
            id);
    }

    if (id < 0 && Identity(type, id) !in created)
    {
        return failReference(
            issue,
            UploadValidationError.unresolvedLocalReference,
            childIndex,
            type,
            id);
    }

    return true;
}

/**
 * Validate UTF-8 and count Unicode scalar values without allocating.
 *
 * Surrogates, overlong sequences and values above U+10FFFF are rejected.
 */
bool utf8ScalarCount(
    scope const(ubyte)[] bytes,
    out size_t count)
    @safe pure nothrow @nogc
{
    count = 0;
    size_t i;

    while (i < bytes.length)
    {
        const b0 = bytes[i];

        if (b0 <= 0x7F)
        {
            ++i;
            ++count;
            continue;
        }

        if (b0 >= 0xC2 && b0 <= 0xDF)
        {
            if (i + 1 >= bytes.length ||
                !continuation(bytes[i + 1]))
            {
                return false;
            }
            i += 2;
            ++count;
            continue;
        }

        if (b0 == 0xE0)
        {
            if (i + 2 >= bytes.length ||
                bytes[i + 1] < 0xA0 ||
                bytes[i + 1] > 0xBF ||
                !continuation(bytes[i + 2]))
            {
                return false;
            }
            i += 3;
            ++count;
            continue;
        }

        if ((b0 >= 0xE1 && b0 <= 0xEC) ||
            (b0 >= 0xEE && b0 <= 0xEF))
        {
            if (i + 2 >= bytes.length ||
                !continuation(bytes[i + 1]) ||
                !continuation(bytes[i + 2]))
            {
                return false;
            }
            i += 3;
            ++count;
            continue;
        }

        if (b0 == 0xED)
        {
            if (i + 2 >= bytes.length ||
                bytes[i + 1] < 0x80 ||
                bytes[i + 1] > 0x9F ||
                !continuation(bytes[i + 2]))
            {
                return false;
            }
            i += 3;
            ++count;
            continue;
        }

        if (b0 == 0xF0)
        {
            if (i + 3 >= bytes.length ||
                bytes[i + 1] < 0x90 ||
                bytes[i + 1] > 0xBF ||
                !continuation(bytes[i + 2]) ||
                !continuation(bytes[i + 3]))
            {
                return false;
            }
            i += 4;
            ++count;
            continue;
        }

        if (b0 >= 0xF1 && b0 <= 0xF3)
        {
            if (i + 3 >= bytes.length ||
                !continuation(bytes[i + 1]) ||
                !continuation(bytes[i + 2]) ||
                !continuation(bytes[i + 3]))
            {
                return false;
            }
            i += 4;
            ++count;
            continue;
        }

        if (b0 == 0xF4)
        {
            if (i + 3 >= bytes.length ||
                bytes[i + 1] < 0x80 ||
                bytes[i + 1] > 0x8F ||
                !continuation(bytes[i + 2]) ||
                !continuation(bytes[i + 3]))
            {
                return false;
            }
            i += 4;
            ++count;
            continue;
        }

        return false;
    }

    return true;
}

bool continuation(ubyte value)
    @safe pure nothrow @nogc
{
    return value >= 0x80 && value <= 0xBF;
}

unittest
{
    import osm.model.owned :
        OwnedMetadata,
        OwnedNode,
        OwnedWay,
        OwnedWayNode;
    import osm.view.location : LocationView;

    OwnedChangeSequence changes;

    OwnedMetadata createMeta;
    createMeta.hasChangeset = true;
    createMeta.changesetId = 42;

    OwnedNode node;
    node.id = -1;
    node.metadata = createMeta;
    node.location = LocationView(48_208_174_300L, 16_373_818_900L);
    changes.entries ~= OwnedChangeEntry.fromNode(ChangeAction.create, node);

    OwnedMetadata modifyMeta;
    modifyMeta.hasChangeset = true;
    modifyMeta.changesetId = 42;
    modifyMeta.hasVersion = true;
    modifyMeta.versionNumber = 3;

    OwnedWay way;
    way.id = 10;
    way.metadata = modifyMeta;
    way.nodes ~= OwnedWayNode(-1);
    changes.entries ~= OwnedChangeEntry.fromWay(ChangeAction.modify, way);

    UploadValidationIssue issue;
    assert(validateUploadChanges(
        changes,
        CapabilityProfile.unbounded(),
        issue));
    assert(issue.ok);
}

unittest
{
    import osm.model.owned :
        OwnedMetadata,
        OwnedNode,
        OwnedWay,
        OwnedWayNode;
    import osm.view.location : LocationView;

    OwnedMetadata meta;
    meta.hasChangeset = true;
    meta.changesetId = 7;

    OwnedChangeSequence changes;

    OwnedWay way;
    way.id = -2;
    way.metadata = meta;
    way.nodes ~= OwnedWayNode(-1);
    changes.entries ~= OwnedChangeEntry.fromWay(ChangeAction.create, way);

    OwnedNode node;
    node.id = -1;
    node.metadata = meta;
    node.location = LocationView(48_000_000_000L, 16_000_000_000L);
    changes.entries ~= OwnedChangeEntry.fromNode(ChangeAction.create, node);

    UploadValidationIssue issue;
    assert(!validateUploadChanges(
        changes,
        CapabilityProfile.unbounded(),
        issue));
    assert(issue.error == UploadValidationError.unresolvedLocalReference);
    assert(issue.entryIndex == 0);
    assert(issue.hasReference);
    assert(issue.referenceType == ElementType.node);
    assert(issue.referenceId == -1);
}

unittest
{
    import osm.model.owned :
        OwnedMetadata,
        OwnedNode,
        OwnedTag,
        ownBytes;
    import osm.view.location : LocationView;

    OwnedMetadata meta;
    meta.hasChangeset = true;
    meta.changesetId = 7;

    OwnedNode node;
    node.id = -1;
    node.metadata = meta;
    node.location = LocationView(48_000_000_000L, 16_000_000_000L);
    node.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"A"));
    node.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"B"));

    OwnedChangeSequence changes;
    changes.entries ~= OwnedChangeEntry.fromNode(ChangeAction.create, node);

    UploadValidationIssue issue;
    assert(!validateUploadChanges(
        changes,
        CapabilityProfile.unbounded(),
        issue));
    assert(issue.error == UploadValidationError.duplicateTagKey);
    assert(issue.childIndex == 1);
}

unittest
{
    size_t count;
    assert(utf8ScalarCount(cast(const(ubyte)[])"abc", count));
    assert(count == 3);

    const ubyte[] euro = [0xE2, 0x82, 0xAC];
    assert(utf8ScalarCount(euro, count));
    assert(count == 1);

    const ubyte[] overlong = [0xC0, 0xAF];
    assert(!utf8ScalarCount(overlong, count));

    const ubyte[] surrogate = [0xED, 0xA0, 0x80];
    assert(!utf8ScalarCount(surrogate, count));
}
