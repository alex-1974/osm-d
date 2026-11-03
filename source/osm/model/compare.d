/**
 * Exact semantic comparison for durable OSM/PBF values.
 *
 * These functions compare the M4 owned meaning rather than protobuf
 * representation. They are allocation-free and preserve order-sensitive OSM
 * structures such as tags, Way references and Relation members.
 *
 * `comparePbfSemantics` additionally reports the first deterministic semantic
 * difference so round-trip failures identify the useful field instead of
 * collapsing to a boolean mismatch.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.model.compare;

import osm.io.pbf.document : PbfDocument, PbfHeader;
import osm.model.owned :
    OwnedDataset,
    OwnedMetadata,
    OwnedNode,
    OwnedRelation,
    OwnedTag,
    OwnedWay;
import osm.view.element : ElementType, OsmId;

/** Field/category identifying the first semantic difference. */
enum PbfSemanticField : ubyte
{
    none,

    headerBBoxPresence,
    headerBBoxLeft,
    headerBBoxRight,
    headerBBoxTop,
    headerBBoxBottom,
    headerRequiredFeatureCount,
    headerRequiredFeature,
    headerOptionalFeatureCount,
    headerOptionalFeature,
    headerWritingProgramPresence,
    headerWritingProgram,
    headerSourcePresence,
    headerSource,
    headerReplicationTimestampPresence,
    headerReplicationTimestamp,
    headerReplicationSequencePresence,
    headerReplicationSequence,
    headerReplicationBaseUrlPresence,
    headerReplicationBaseUrl,

    nodeCount,
    wayCount,
    relationCount,
    elementId,

    latitude,
    longitude,

    metadataVersionPresence,
    metadataVersion,
    metadataTimestampPresence,
    metadataTimestamp,
    metadataChangesetPresence,
    metadataChangeset,
    metadataUserIdPresence,
    metadataUserId,
    metadataUsernamePresence,
    metadataUsername,
    metadataVisibilityPresence,
    metadataVisibility,

    tagCount,
    tagKey,
    tagValue,

    wayNodeCount,
    wayNodeId,
    wayNodeLocationPresence,
    wayNodeLatitude,
    wayNodeLongitude,

    relationMemberCount,
    relationMemberType,
    relationMemberId,
    relationMemberRole,
}

/**
 * Location of the first semantic mismatch.
 *
 * `elementIndex` identifies the element within its type array. When
 * `hasElement` is true, `elementType` and `elementId` identify the left
 * document's element (or the right element when the left array ended first).
 * `childIndex` identifies a tag, Way node reference, Relation member or
 * HeaderBlock feature when `hasChild` is true.
 *
 * `.init` means no difference.
 */
struct PbfSemanticDifference
{
    PbfSemanticField field = PbfSemanticField.none;
    bool hasElement;
    ElementType elementType;
    OsmId elementId;
    size_t elementIndex;
    bool hasChild;
    size_t childIndex;

    @property bool equal() const @safe pure nothrow @nogc
    {
        return field == PbfSemanticField.none;
    }
}

/**
 * Compare complete known PBF semantics and report the first mismatch.
 *
 * Comparison order is HeaderBlock, element counts, Nodes, Ways, Relations.
 * Within an element, identity/location/metadata precede ordered child arrays.
 *
 * Returns:
 *   `true` when all known semantics are equal; otherwise `false` and
 *   `difference` identifies the first mismatch.
 */
bool comparePbfSemantics(
    ref const PbfDocument a,
    ref const PbfDocument b,
    out PbfSemanticDifference difference)
    @safe pure nothrow @nogc
{
    difference = PbfSemanticDifference.init;

    if (!compareHeader(a.header, b.header, difference))
        return false;

    if (a.data.nodes.length != b.data.nodes.length)
    {
        difference.field = PbfSemanticField.nodeCount;
        return false;
    }
    if (a.data.ways.length != b.data.ways.length)
    {
        difference.field = PbfSemanticField.wayCount;
        return false;
    }
    if (a.data.relations.length != b.data.relations.length)
    {
        difference.field = PbfSemanticField.relationCount;
        return false;
    }

    foreach (i; 0 .. a.data.nodes.length)
    {
        if (!compareNode(a.data.nodes[i], b.data.nodes[i], i, difference))
            return false;
    }

    foreach (i; 0 .. a.data.ways.length)
    {
        if (!compareWay(a.data.ways[i], b.data.ways[i], i, difference))
            return false;
    }

    foreach (i; 0 .. a.data.relations.length)
    {
        if (!compareRelation(
                a.data.relations[i],
                b.data.relations[i],
                i,
                difference))
        {
            return false;
        }
    }

    return true;
}

/** Compare all owned OSM element semantics exactly. */
bool sameOsmSemantics(
    ref const OwnedDataset a,
    ref const OwnedDataset b)
    @safe pure nothrow @nogc
{
    if (a.nodes.length != b.nodes.length ||
        a.ways.length != b.ways.length ||
        a.relations.length != b.relations.length)
    {
        return false;
    }

    foreach (i; 0 .. a.nodes.length)
        if (!sameNode(a.nodes[i], b.nodes[i]))
            return false;

    foreach (i; 0 .. a.ways.length)
        if (!sameWay(a.ways[i], b.ways[i]))
            return false;

    foreach (i; 0 .. a.relations.length)
        if (!sameRelation(a.relations[i], b.relations[i]))
            return false;

    return true;
}

/** Compare known PBF HeaderBlock semantics exactly, including feature order. */
bool samePbfHeaderSemantics(
    ref const PbfHeader a,
    ref const PbfHeader b)
    @safe pure nothrow @nogc
{
    PbfSemanticDifference difference;
    return compareHeader(a, b, difference);
}

/** Compare the known semantic content of two PBF documents. */
bool samePbfSemantics(
    ref const PbfDocument a,
    ref const PbfDocument b)
    @safe pure nothrow @nogc
{
    PbfSemanticDifference difference;
    return comparePbfSemantics(a, b, difference);
}

/** Compare captured raw sources byte-for-byte. */
bool samePbfRawSource(
    ref const PbfDocument a,
    ref const PbfDocument b)
    @safe pure nothrow @nogc
{
    return a.preservation.source.bytes ==
           b.preservation.source.bytes;
}

private bool compareHeader(
    ref const PbfHeader a,
    ref const PbfHeader b,
    ref PbfSemanticDifference difference)
    @safe pure nothrow @nogc
{
    if (a.hasBBox != b.hasBBox)
        return fail(difference, PbfSemanticField.headerBBoxPresence);

    if (a.hasBBox)
    {
        if (a.bbox.left != b.bbox.left)
            return fail(difference, PbfSemanticField.headerBBoxLeft);
        if (a.bbox.right != b.bbox.right)
            return fail(difference, PbfSemanticField.headerBBoxRight);
        if (a.bbox.top != b.bbox.top)
            return fail(difference, PbfSemanticField.headerBBoxTop);
        if (a.bbox.bottom != b.bbox.bottom)
            return fail(difference, PbfSemanticField.headerBBoxBottom);
    }

    if (a.requiredFeatures.length != b.requiredFeatures.length)
        return fail(
            difference,
            PbfSemanticField.headerRequiredFeatureCount);

    foreach (i; 0 .. a.requiredFeatures.length)
    {
        if (a.requiredFeatures[i] != b.requiredFeatures[i])
            return failChild(
                difference,
                PbfSemanticField.headerRequiredFeature,
                i);
    }

    if (a.optionalFeatures.length != b.optionalFeatures.length)
        return fail(
            difference,
            PbfSemanticField.headerOptionalFeatureCount);

    foreach (i; 0 .. a.optionalFeatures.length)
    {
        if (a.optionalFeatures[i] != b.optionalFeatures[i])
            return failChild(
                difference,
                PbfSemanticField.headerOptionalFeature,
                i);
    }

    if (a.hasWritingProgram != b.hasWritingProgram)
        return fail(
            difference,
            PbfSemanticField.headerWritingProgramPresence);
    if (a.hasWritingProgram && a.writingProgram != b.writingProgram)
        return fail(
            difference,
            PbfSemanticField.headerWritingProgram);

    if (a.hasSource != b.hasSource)
        return fail(difference, PbfSemanticField.headerSourcePresence);
    if (a.hasSource && a.source != b.source)
        return fail(difference, PbfSemanticField.headerSource);

    if (a.hasReplicationTimestamp != b.hasReplicationTimestamp)
        return fail(
            difference,
            PbfSemanticField.headerReplicationTimestampPresence);
    if (a.hasReplicationTimestamp &&
        a.replicationTimestamp != b.replicationTimestamp)
    {
        return fail(
            difference,
            PbfSemanticField.headerReplicationTimestamp);
    }

    if (a.hasReplicationSequenceNumber !=
        b.hasReplicationSequenceNumber)
    {
        return fail(
            difference,
            PbfSemanticField.headerReplicationSequencePresence);
    }
    if (a.hasReplicationSequenceNumber &&
        a.replicationSequenceNumber != b.replicationSequenceNumber)
    {
        return fail(
            difference,
            PbfSemanticField.headerReplicationSequence);
    }

    if (a.hasReplicationBaseUrl != b.hasReplicationBaseUrl)
        return fail(
            difference,
            PbfSemanticField.headerReplicationBaseUrlPresence);
    if (a.hasReplicationBaseUrl &&
        a.replicationBaseUrl != b.replicationBaseUrl)
    {
        return fail(
            difference,
            PbfSemanticField.headerReplicationBaseUrl);
    }

    return true;
}

private bool compareNode(
    ref const OwnedNode a,
    ref const OwnedNode b,
    size_t elementIndex,
    ref PbfSemanticDifference difference)
    @safe pure nothrow @nogc
{
    setElement(difference, ElementType.node, a.id, elementIndex);

    if (a.id != b.id)
        return fail(difference, PbfSemanticField.elementId);
    if (a.location.latitudeNanodegrees !=
        b.location.latitudeNanodegrees)
    {
        return fail(difference, PbfSemanticField.latitude);
    }
    if (a.location.longitudeNanodegrees !=
        b.location.longitudeNanodegrees)
    {
        return fail(difference, PbfSemanticField.longitude);
    }
    if (!compareMetadata(a.metadata, b.metadata, difference))
        return false;
    if (!compareTags(a.tags, b.tags, difference))
        return false;

    clearElement(difference);
    return true;
}

private bool compareWay(
    ref const OwnedWay a,
    ref const OwnedWay b,
    size_t elementIndex,
    ref PbfSemanticDifference difference)
    @safe pure nothrow @nogc
{
    setElement(difference, ElementType.way, a.id, elementIndex);

    if (a.id != b.id)
        return fail(difference, PbfSemanticField.elementId);
    if (!compareMetadata(a.metadata, b.metadata, difference))
        return false;
    if (!compareTags(a.tags, b.tags, difference))
        return false;

    if (a.nodes.length != b.nodes.length)
        return fail(difference, PbfSemanticField.wayNodeCount);

    foreach (i; 0 .. a.nodes.length)
    {
        difference.hasChild = true;
        difference.childIndex = i;

        if (a.nodes[i].id != b.nodes[i].id)
            return fail(difference, PbfSemanticField.wayNodeId);
        if (a.nodes[i].hasLocation != b.nodes[i].hasLocation)
        {
            return fail(
                difference,
                PbfSemanticField.wayNodeLocationPresence);
        }
        if (a.nodes[i].hasLocation)
        {
            if (a.nodes[i].location.latitudeNanodegrees !=
                b.nodes[i].location.latitudeNanodegrees)
            {
                return fail(
                    difference,
                    PbfSemanticField.wayNodeLatitude);
            }
            if (a.nodes[i].location.longitudeNanodegrees !=
                b.nodes[i].location.longitudeNanodegrees)
            {
                return fail(
                    difference,
                    PbfSemanticField.wayNodeLongitude);
            }
        }
    }

    clearElement(difference);
    return true;
}

private bool compareRelation(
    ref const OwnedRelation a,
    ref const OwnedRelation b,
    size_t elementIndex,
    ref PbfSemanticDifference difference)
    @safe pure nothrow @nogc
{
    setElement(difference, ElementType.relation, a.id, elementIndex);

    if (a.id != b.id)
        return fail(difference, PbfSemanticField.elementId);
    if (!compareMetadata(a.metadata, b.metadata, difference))
        return false;
    if (!compareTags(a.tags, b.tags, difference))
        return false;

    if (a.members.length != b.members.length)
        return fail(
            difference,
            PbfSemanticField.relationMemberCount);

    foreach (i; 0 .. a.members.length)
    {
        difference.hasChild = true;
        difference.childIndex = i;

        if (a.members[i].type != b.members[i].type)
            return fail(
                difference,
                PbfSemanticField.relationMemberType);
        if (a.members[i].id != b.members[i].id)
            return fail(
                difference,
                PbfSemanticField.relationMemberId);
        if (a.members[i].role != b.members[i].role)
            return fail(
                difference,
                PbfSemanticField.relationMemberRole);
    }

    clearElement(difference);
    return true;
}

private bool compareMetadata(
    ref const OwnedMetadata a,
    ref const OwnedMetadata b,
    ref PbfSemanticDifference difference)
    @safe pure nothrow @nogc
{
    if (a.hasVersion != b.hasVersion)
        return fail(
            difference,
            PbfSemanticField.metadataVersionPresence);
    if (a.hasVersion && a.versionNumber != b.versionNumber)
        return fail(difference, PbfSemanticField.metadataVersion);

    if (a.hasTimestamp != b.hasTimestamp)
        return fail(
            difference,
            PbfSemanticField.metadataTimestampPresence);
    if (a.hasTimestamp &&
        a.timestampMilliseconds != b.timestampMilliseconds)
    {
        return fail(difference, PbfSemanticField.metadataTimestamp);
    }

    if (a.hasChangeset != b.hasChangeset)
        return fail(
            difference,
            PbfSemanticField.metadataChangesetPresence);
    if (a.hasChangeset && a.changesetId != b.changesetId)
        return fail(difference, PbfSemanticField.metadataChangeset);

    if (a.hasUserId != b.hasUserId)
        return fail(
            difference,
            PbfSemanticField.metadataUserIdPresence);
    if (a.hasUserId && a.userId != b.userId)
        return fail(difference, PbfSemanticField.metadataUserId);

    if (a.hasUsername != b.hasUsername)
        return fail(
            difference,
            PbfSemanticField.metadataUsernamePresence);
    if (a.hasUsername && a.username != b.username)
        return fail(difference, PbfSemanticField.metadataUsername);

    if (a.hasVisibility != b.hasVisibility)
        return fail(
            difference,
            PbfSemanticField.metadataVisibilityPresence);
    if (a.hasVisibility && a.visible != b.visible)
        return fail(difference, PbfSemanticField.metadataVisibility);

    return true;
}

private bool compareTags(
    scope const(OwnedTag)[] a,
    scope const(OwnedTag)[] b,
    ref PbfSemanticDifference difference)
    @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return fail(difference, PbfSemanticField.tagCount);

    foreach (i; 0 .. a.length)
    {
        difference.hasChild = true;
        difference.childIndex = i;

        if (a[i].key != b[i].key)
            return fail(difference, PbfSemanticField.tagKey);
        if (a[i].value != b[i].value)
            return fail(difference, PbfSemanticField.tagValue);
    }

    difference.hasChild = false;
    difference.childIndex = 0;
    return true;
}

private bool sameNode(
    ref const OwnedNode a,
    ref const OwnedNode b)
    @safe pure nothrow @nogc
{
    if (a.id != b.id ||
        a.location.latitudeNanodegrees !=
            b.location.latitudeNanodegrees ||
        a.location.longitudeNanodegrees !=
            b.location.longitudeNanodegrees ||
        !sameMetadata(a.metadata, b.metadata))
    {
        return false;
    }

    return sameTags(a.tags, b.tags);
}

private bool sameWay(
    ref const OwnedWay a,
    ref const OwnedWay b)
    @safe pure nothrow @nogc
{
    if (a.id != b.id ||
        !sameMetadata(a.metadata, b.metadata) ||
        !sameTags(a.tags, b.tags) ||
        a.nodes.length != b.nodes.length)
    {
        return false;
    }

    foreach (i; 0 .. a.nodes.length)
    {
        const left = a.nodes[i];
        const right = b.nodes[i];

        if (left.id != right.id ||
            left.hasLocation != right.hasLocation)
        {
            return false;
        }

        if (left.hasLocation &&
            (left.location.latitudeNanodegrees !=
                 right.location.latitudeNanodegrees ||
             left.location.longitudeNanodegrees !=
                 right.location.longitudeNanodegrees))
        {
            return false;
        }
    }

    return true;
}

private bool sameRelation(
    ref const OwnedRelation a,
    ref const OwnedRelation b)
    @safe pure nothrow @nogc
{
    if (a.id != b.id ||
        !sameMetadata(a.metadata, b.metadata) ||
        !sameTags(a.tags, b.tags) ||
        a.members.length != b.members.length)
    {
        return false;
    }

    foreach (i; 0 .. a.members.length)
    {
        if (a.members[i].type != b.members[i].type ||
            a.members[i].id != b.members[i].id ||
            a.members[i].role != b.members[i].role)
        {
            return false;
        }
    }

    return true;
}

private bool sameMetadata(
    ref const OwnedMetadata a,
    ref const OwnedMetadata b)
    @safe pure nothrow @nogc
{
    return a.hasVersion == b.hasVersion &&
           (!a.hasVersion || a.versionNumber == b.versionNumber) &&
           a.hasTimestamp == b.hasTimestamp &&
           (!a.hasTimestamp ||
            a.timestampMilliseconds == b.timestampMilliseconds) &&
           a.hasChangeset == b.hasChangeset &&
           (!a.hasChangeset || a.changesetId == b.changesetId) &&
           a.hasUserId == b.hasUserId &&
           (!a.hasUserId || a.userId == b.userId) &&
           a.hasUsername == b.hasUsername &&
           (!a.hasUsername || a.username == b.username) &&
           a.hasVisibility == b.hasVisibility &&
           (!a.hasVisibility || a.visible == b.visible);
}

private bool sameTags(
    scope const(OwnedTag)[] a,
    scope const(OwnedTag)[] b)
    @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;

    foreach (i; 0 .. a.length)
    {
        if (a[i].key != b[i].key ||
            a[i].value != b[i].value)
        {
            return false;
        }
    }
    return true;
}

private bool fail(
    ref PbfSemanticDifference difference,
    PbfSemanticField field)
    @safe pure nothrow @nogc
{
    difference.field = field;
    return false;
}

private bool failChild(
    ref PbfSemanticDifference difference,
    PbfSemanticField field,
    size_t childIndex)
    @safe pure nothrow @nogc
{
    difference.field = field;
    difference.hasChild = true;
    difference.childIndex = childIndex;
    return false;
}

private void setElement(
    ref PbfSemanticDifference difference,
    ElementType type,
    OsmId id,
    size_t elementIndex)
    @safe pure nothrow @nogc
{
    difference.hasElement = true;
    difference.elementType = type;
    difference.elementId = id;
    difference.elementIndex = elementIndex;
    difference.hasChild = false;
    difference.childIndex = 0;
}

private void clearElement(ref PbfSemanticDifference difference)
    @safe pure nothrow @nogc
{
    difference.hasElement = false;
    difference.elementId = 0;
    difference.elementIndex = 0;
    difference.hasChild = false;
    difference.childIndex = 0;
}

unittest
{
    OwnedDataset a;
    OwnedDataset b;
    assert(sameOsmSemantics(a, b));

    OwnedNode node;
    node.id = 1;
    a.nodes ~= node;
    assert(!sameOsmSemantics(a, b));

    b.nodes ~= node;
    assert(sameOsmSemantics(a, b));
}

unittest
{
    PbfDocument a = PbfDocument.create();
    PbfDocument b = PbfDocument.create();

    OwnedNode left;
    left.id = 7;
    left.tags ~= OwnedTag(
        cast(immutable(ubyte)[])"k",
        cast(immutable(ubyte)[])"left");
    a.data.nodes ~= left;

    OwnedNode right;
    right.id = 7;
    right.tags ~= OwnedTag(
        cast(immutable(ubyte)[])"k",
        cast(immutable(ubyte)[])"right");
    b.data.nodes ~= right;

    PbfSemanticDifference difference;
    assert(!comparePbfSemantics(a, b, difference));
    assert(difference.field == PbfSemanticField.tagValue);
    assert(difference.hasElement);
    assert(difference.elementType == ElementType.node);
    assert(difference.elementId == 7);
    assert(difference.elementIndex == 0);
    assert(difference.hasChild);
    assert(difference.childIndex == 0);
}
