/**
 * Exact semantic comparison for durable OSM/PBF values.
 *
 * These functions compare the M4 owned meaning rather than protobuf
 * representation. They are allocation-free and preserve order-sensitive OSM
 * structures such as tags, Way references and Relation members.
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
    if (a.hasBBox != b.hasBBox)
        return false;
    if (a.hasBBox &&
        (a.bbox.left != b.bbox.left ||
         a.bbox.right != b.bbox.right ||
         a.bbox.top != b.bbox.top ||
         a.bbox.bottom != b.bbox.bottom))
    {
        return false;
    }

    if (!sameBytesArray(a.requiredFeatures, b.requiredFeatures) ||
        !sameBytesArray(a.optionalFeatures, b.optionalFeatures))
    {
        return false;
    }

    return a.hasWritingProgram == b.hasWritingProgram &&
           (!a.hasWritingProgram || a.writingProgram == b.writingProgram) &&
           a.hasSource == b.hasSource &&
           (!a.hasSource || a.source == b.source) &&
           a.hasReplicationTimestamp == b.hasReplicationTimestamp &&
           (!a.hasReplicationTimestamp ||
            a.replicationTimestamp == b.replicationTimestamp) &&
           a.hasReplicationSequenceNumber ==
               b.hasReplicationSequenceNumber &&
           (!a.hasReplicationSequenceNumber ||
            a.replicationSequenceNumber == b.replicationSequenceNumber) &&
           a.hasReplicationBaseUrl == b.hasReplicationBaseUrl &&
           (!a.hasReplicationBaseUrl ||
            a.replicationBaseUrl == b.replicationBaseUrl);
}

/** Compare the known semantic content of two PBF documents. */
bool samePbfSemantics(
    ref const PbfDocument a,
    ref const PbfDocument b)
    @safe pure nothrow @nogc
{
    return samePbfHeaderSemantics(a.header, b.header) &&
           sameOsmSemantics(a.data, b.data);
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

private bool sameNode(
    ref const OwnedNode a,
    ref const OwnedNode b)
    @safe pure nothrow @nogc
{
    return a.id == b.id &&
           a.location.latitudeNanodegrees ==
               b.location.latitudeNanodegrees &&
           a.location.longitudeNanodegrees ==
               b.location.longitudeNanodegrees &&
           sameMetadata(a.metadata, b.metadata) &&
           sameTags(a.tags, b.tags);
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

private bool sameBytesArray(
    scope const(immutable(ubyte)[])[] a,
    scope const(immutable(ubyte)[])[] b)
    @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;

    foreach (i; 0 .. a.length)
        if (a[i] != b[i])
            return false;

    return true;
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
