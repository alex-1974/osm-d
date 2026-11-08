/**
 * Bounded OSM API history XML projection.
 *
 * This decoder specializes ordinary OSM XML only where historical semantics
 * differ from live element semantics: a deleted Node may omit lat/lon. Way and
 * Relation payloads reuse the existing semantic XML parsers.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-08
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.history.reader;

import dxml.parser :
    XmlEntityType = EntityType,
    XMLParsingException,
    parseXML,
    simpleXML;
import dxml.util : decodeXML;
import osm.history :
    HistoricalNodeVersion,
    HistoricalRelationVersion,
    HistoricalWayVersion;
import osm.io.xml.byte_range :
    XmlCharRange,
    XmlSourceException;
import osm.io.xml.reader :
    OsmXmlReadError,
    OsmXmlReadOptions,
    OsmXmlReadStatus,
    parseSemanticXmlCoordinate,
    parseSemanticXmlLong,
    parseSemanticXmlMetadataAttribute,
    parseSemanticXmlRelation,
    parseSemanticXmlTag,
    parseSemanticXmlWay,
    prepareSemanticXmlEncoding,
    semanticXmlPosition,
    semanticXmlWhitespace;
import osm.model.owned :
    OwnedMetadata,
    OwnedRelation,
    OwnedTag,
    OwnedWay;
import osm.view.element : ElementType;
import osm.view.location : LocationView;
import std.algorithm.comparison : equal;
import transport.source :
    ByteSource,
    ReadError;

package(osm):

/** Bounded controls for one history response. */
struct HistoryXmlReadOptions
{
    OsmXmlReadOptions xml;
    size_t maximumVersions;
}

/** Read Node versions from one OSM /node/{id}/history response. */
bool readNodeHistoryXml(
    ByteSource source,
    out HistoricalNodeVersion[] versions,
    out OsmXmlReadStatus status,
    HistoryXmlReadOptions options = HistoryXmlReadOptions.init)
    @trusted
{
    return readHistory!HistoricalNodeVersion(
        source,
        versions,
        status,
        options);
}

/** Read Way versions from one OSM /way/{id}/history response. */
bool readWayHistoryXml(
    ByteSource source,
    out HistoricalWayVersion[] versions,
    out OsmXmlReadStatus status,
    HistoryXmlReadOptions options = HistoryXmlReadOptions.init)
    @trusted
{
    return readHistory!HistoricalWayVersion(
        source,
        versions,
        status,
        options);
}

/** Read Relation versions from one OSM /relation/{id}/history response. */
bool readRelationHistoryXml(
    ByteSource source,
    out HistoricalRelationVersion[] versions,
    out OsmXmlReadStatus status,
    HistoryXmlReadOptions options = HistoryXmlReadOptions.init)
    @trusted
{
    return readHistory!HistoricalRelationVersion(
        source,
        versions,
        status,
        options);
}

private:

enum size_t defaultMaximumHistoryVersions = 100_000;
enum size_t defaultMaximumChildren = 1_000_000;

size_t versionLimit(HistoryXmlReadOptions options)
    @safe pure nothrow @nogc
{
    return options.maximumVersions == 0
        ? defaultMaximumHistoryVersions
        : options.maximumVersions;
}

size_t childLimit(HistoryXmlReadOptions options)
    @safe pure nothrow @nogc
{
    return options.xml.maximumChildrenPerElement == 0
        ? defaultMaximumChildren
        : options.xml.maximumChildrenPerElement;
}

bool readHistory(T)(
    ByteSource source,
    out T[] versions,
    out OsmXmlReadStatus status,
    HistoryXmlReadOptions options)
{
    versions = null;
    status = OsmXmlReadStatus.init;

    if (source is null)
    {
        status.error = OsmXmlReadError.transportFailure;
        status.transportError = ReadError.sourceFailure;
        return false;
    }

    ulong startOffset;
    if (!prepareSemanticXmlEncoding(
            source,
            options.xml,
            startOffset,
            status))
        return false;

    try
    {
        auto input = XmlCharRange(
            source,
            options.xml.bufferSize,
            startOffset);
        auto xml = parseXML!simpleXML(input);

        while (!xml.empty && semanticXmlWhitespace(xml.front))
            xml.popFront();

        if (xml.empty ||
            xml.front.type != XmlEntityType.elementStart ||
            !equal(xml.front.name.save, "osm"))
        {
            if (!xml.empty)
                setPosition(status, xml.front);
            status.error = OsmXmlReadError.invalidStructure;
            return false;
        }

        if (!validateRoot(xml.front, status))
            return false;

        xml.popFront();

        T[] parsed;
        while (!xml.empty)
        {
            if (semanticXmlWhitespace(xml.front))
            {
                xml.popFront();
                continue;
            }

            if (xml.front.type == XmlEntityType.elementEnd &&
                equal(xml.front.name.save, "osm"))
            {
                xml.popFront();

                while (!xml.empty && semanticXmlWhitespace(xml.front))
                    xml.popFront();

                if (!xml.empty)
                {
                    setPosition(status, xml.front);
                    status.error = OsmXmlReadError.invalidStructure;
                    return false;
                }

                if (parsed.length == 0)
                {
                    status.error = OsmXmlReadError.invalidStructure;
                    return false;
                }

                versions = parsed;
                status = OsmXmlReadStatus.init;
                return true;
            }

            if (xml.front.type != XmlEntityType.elementStart ||
                !equal(xml.front.name.save, elementName!T))
            {
                setPosition(status, xml.front);
                status.error = OsmXmlReadError.unsupportedContent;
                return false;
            }

            if (parsed.length >= versionLimit(options))
            {
                setPosition(status, xml.front);
                status.error = OsmXmlReadError.resourceLimit;
                return false;
            }

            T value;
            static if (is(T == HistoricalNodeVersion))
            {
                if (!parseHistoricalNode(
                        xml,
                        value,
                        status,
                        options))
                    return false;
            }
            else static if (is(T == HistoricalWayVersion))
            {
                OwnedWay way;
                ulong tagCount;
                if (!parseSemanticXmlWay(
                        xml,
                        way,
                        tagCount,
                        status,
                        options.xml))
                    return false;
                value = HistoricalWayVersion.fromOwned(way);
            }
            else
            {
                OwnedRelation relation;
                ulong tagCount;
                if (!parseSemanticXmlRelation(
                        xml,
                        relation,
                        tagCount,
                        status,
                        options.xml))
                    return false;
                value = HistoricalRelationVersion.fromOwned(relation);
            }

            parsed ~= value;
        }

        status.error = OsmXmlReadError.invalidStructure;
        return false;
    }
    catch (XmlSourceException e)
    {
        status.error = OsmXmlReadError.transportFailure;
        status.transportError = e.error;
        status.byteOffset = e.offset;
        return false;
    }
    catch (XMLParsingException e)
    {
        status.error = OsmXmlReadError.malformedXml;
        status.line = e.pos.line;
        status.column = e.pos.col;
        return false;
    }
}

bool validateRoot(Entity)(
    ref Entity entity,
    ref OsmXmlReadStatus status)
{
    bool hasVersion;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        if (equal(attr.name.save, "version"))
        {
            const value = decodeXML(attr.value);
            if (value != "0.6")
            {
                setPosition(status, entity);
                status.error = OsmXmlReadError.unsupportedVersion;
                return false;
            }
            hasVersion = true;
        }
        // Other document-envelope attributes such as generator/copyright are
        // provenance, not history semantics.
        attrs.popFront();
    }

    if (!hasVersion)
    {
        setPosition(status, entity);
        status.error = OsmXmlReadError.missingAttribute;
        return false;
    }

    return true;
}

bool parseHistoricalNode(R)(
    ref R xml,
    out HistoricalNodeVersion node,
    ref OsmXmlReadStatus status,
    HistoryXmlReadOptions options)
{
    node = HistoricalNodeVersion.init;

    auto entity = xml.front;
    bool hasId;
    bool hasLat;
    bool hasLon;
    long lat;
    long lon;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;

        if (equal(attr.name.save, "id"))
        {
            const value = decodeXML(attr.value);
            if (!parseSemanticXmlLong(value, node.id))
            {
                setPosition(status, entity);
                status.error = OsmXmlReadError.invalidAttribute;
                return false;
            }
            hasId = true;
        }
        else if (equal(attr.name.save, "lat"))
        {
            const value = decodeXML(attr.value);
            if (!parseSemanticXmlCoordinate(
                    value,
                    90,
                    lat,
                    status))
            {
                setPosition(status, entity);
                return false;
            }
            hasLat = true;
        }
        else if (equal(attr.name.save, "lon"))
        {
            const value = decodeXML(attr.value);
            if (!parseSemanticXmlCoordinate(
                    value,
                    180,
                    lon,
                    status))
            {
                setPosition(status, entity);
                return false;
            }
            hasLon = true;
        }
        else if (!parseSemanticXmlMetadataAttribute(
                attr,
                node.metadata,
                status,
                entity))
        {
            return false;
        }

        attrs.popFront();
    }

    const deleted =
        node.metadata.hasVisibility &&
        !node.metadata.visible;

    if (!hasId ||
        hasLat != hasLon ||
        (!deleted && (!hasLat || !hasLon)))
    {
        setPosition(status, entity);
        status.error = OsmXmlReadError.missingAttribute;
        return false;
    }

    status.hasElementIdentity = true;
    status.elementType = ElementType.node;
    status.elementId = node.id;

    node.hasLocation = hasLat;
    if (node.hasLocation)
        node.location = LocationView(lat, lon);

    xml.popFront();
    size_t children;

    while (!xml.empty)
    {
        if (semanticXmlWhitespace(xml.front))
        {
            xml.popFront();
            continue;
        }

        if (xml.front.type == XmlEntityType.elementEnd &&
            equal(xml.front.name.save, "node"))
        {
            xml.popFront();
            return true;
        }

        if (xml.front.type != XmlEntityType.elementStart ||
            !equal(xml.front.name.save, "tag"))
        {
            setPosition(status, xml.front);
            status.error = OsmXmlReadError.unsupportedContent;
            return false;
        }

        if (++children > childLimit(options))
        {
            setPosition(status, xml.front);
            status.error = OsmXmlReadError.resourceLimit;
            return false;
        }

        OwnedTag tag;
        if (!parseSemanticXmlTag(xml, tag, status))
            return false;
        node.tags ~= tag;
    }

    status.error = OsmXmlReadError.invalidStructure;
    return false;
}

void setPosition(Entity)(
    ref OsmXmlReadStatus status,
    Entity entity)
{
    semanticXmlPosition(status, entity);
}

template elementName(T)
{
    static if (is(T == HistoricalNodeVersion))
        enum elementName = "node";
    else static if (is(T == HistoricalWayVersion))
        enum elementName = "way";
    else
        enum elementName = "relation";
}

unittest
{
    import osm.history :
        HistoricalVisibility;
    import transport.source : MemorySource;

    enum xml =
        "<osm version=\"0.6\" generator=\"OpenStreetMap server\">" ~
        "<node id=\"42\" lat=\"48.1\" lon=\"16.2\" " ~
        "version=\"1\" visible=\"true\"/>" ~
        "<node id=\"42\" version=\"2\" visible=\"false\"/>" ~
        "</osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    HistoricalNodeVersion[] versions;
    OsmXmlReadStatus status;
    assert(readNodeHistoryXml(source, versions, status));
    assert(versions.length == 2);
    assert(versions[0].hasLocation);
    assert(!versions[1].hasLocation);
    assert(versions[1].visibility ==
        HistoricalVisibility.deleted);
}
