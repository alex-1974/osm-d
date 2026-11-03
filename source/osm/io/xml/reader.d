/**
 * Streaming semantic reader for ordinary OSM XML 0.6 documents.
 *
 * The reader consumes bytes from transport-d and uses dxml internally. It
 * materializes at most one OSM element at a time before invoking the consumer
 * callback; retaining delivered owned values is the consumer's choice.
 *
 * XML parser entities and ranges never cross the public API. Unknown
 * attributes/elements fail explicitly rather than being converted to tags or
 * silently discarded.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.xml.reader;

import core.time : hnsecs;
import dxml.parser :
    XmlEntityType = EntityType,
    XMLParsingException,
    parseXML,
    simpleXML;
import dxml.util : decodeXML;
import osm.io.xml.byte_range :
    XmlCharRange,
    XmlSourceException;
import osm.io.xml.document :
    OsmXmlBounds,
    OsmXmlDocument,
    OsmXmlDocumentInfo;
import osm.model.owned :
    OwnedBytes,
    OwnedDataset,
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
import std.algorithm.comparison : equal;
import std.algorithm.searching : startsWith;
import std.datetime.date : DateTimeException;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;
import std.string : indexOf;
import transport.source :
    ByteSource,
    ReadError,
    ReadLimits;

/** Stable high-level failure category for OSM XML reading. */
enum OsmXmlReadError : ubyte
{
    none,
    transportFailure,
    malformedXml,
    unsupportedEncoding,
    unsupportedVersion,
    unsupportedContent,
    missingAttribute,
    invalidAttribute,
    precisionLoss,
    resourceLimit,
    invalidStructure,
}

/**
 * Diagnostic from one OSM XML read.
 *
 * line/column are 1-based when supplied by dxml and zero when no XML entity
 * position was available. elementType/elementId are meaningful only when the
 * failing object identity had already been decoded.
 */
struct OsmXmlReadStatus
{
    OsmXmlReadError error = OsmXmlReadError.none;
    ReadError transportError = ReadError.none;
    ulong byteOffset;
    int line;
    int column;
    ElementType elementType;
    OsmId elementId;
    bool hasElementIdentity;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == OsmXmlReadError.none;
    }
}

/**
 * Bounded-reader controls. Zero values select documented defaults.
 *
 * bufferSize defaults to 64 KiB. maximumChildrenPerElement defaults to
 * 1,000,000 and bounds allocation for one pathological OSM object while
 * remaining well above normal OSM API limits. maximumXmlDeclarationBytes
 * defaults to 4096.
 */
struct OsmXmlReadOptions
{
    size_t bufferSize;
    size_t maximumChildrenPerElement;
    size_t maximumXmlDeclarationBytes;
}

/** Counts and document-envelope metadata from one complete successful read. */
struct OsmXmlReadSummary
{
    OsmXmlDocumentInfo info;
    ulong nodes;
    ulong ways;
    ulong relations;
    ulong tags;
    ulong wayNodeReferences;
    ulong relationMembers;
}

/**
 * Stateless streaming OSM XML reader.
 *
 * .init is ready to use. A false return always accompanies a non-ok status.
 * Successfully delivered callbacks before a later document failure are not
 * rolled back; callers requiring transactional whole-document materialization
 * should use readOsmXmlDocument.
 */
struct OsmXmlReader
{
    bool read(Handler)(
        ByteSource source,
        ref Handler handler,
        out OsmXmlReadSummary summary,
        out OsmXmlReadStatus status,
        OsmXmlReadOptions options = OsmXmlReadOptions.init)
        @trusted
    {
        summary = OsmXmlReadSummary.init;
        status = OsmXmlReadStatus.init;

        if (source is null)
        {
            status.error = OsmXmlReadError.transportFailure;
            status.transportError = ReadError.sourceFailure;
            return false;
        }

        ulong startOffset;
        if (!prepareEncoding(source, options, startOffset, status))
            return false;

        try
        {
            auto input = XmlCharRange(source, options.bufferSize, startOffset);
            auto xml = parseXML!simpleXML(input);

            if (xml.empty)
            {
                status.error = OsmXmlReadError.invalidStructure;
                return false;
            }

            if (xml.front.type != XmlEntityType.elementStart ||
                !equal(xml.front.name.save, "osm"))
            {
                setPosition(status, xml.front);
                status.error = OsmXmlReadError.invalidStructure;
                return false;
            }

            if (!parseRootAttributes(xml.front, summary.info, status))
                return false;

            xml.popFront();

            while (!xml.empty)
            {
                if (xml.front.type == XmlEntityType.elementEnd &&
                    equal(xml.front.name.save, "osm"))
                {
                    xml.popFront();
                    if (!xml.empty)
                    {
                        setPosition(status, xml.front);
                        status.error = OsmXmlReadError.invalidStructure;
                        return false;
                    }
                    return true;
                }

                if (xml.front.type != XmlEntityType.elementStart)
                {
                    setPosition(status, xml.front);
                    status.error = OsmXmlReadError.unsupportedContent;
                    return false;
                }

                if (equal(xml.front.name.save, "bounds"))
                {
                    if (!parseBounds(xml, summary.info, status))
                        return false;
                }
                else if (equal(xml.front.name.save, "node"))
                {
                    OwnedNode node;
                    ulong tagCount;
                    if (!parseNode(xml, node, tagCount, status, options))
                        return false;
                    ++summary.nodes;
                    summary.tags += tagCount;
                    deliverNode(handler, node);
                }
                else if (equal(xml.front.name.save, "way"))
                {
                    OwnedWay way;
                    ulong tagCount;
                    if (!parseWay(xml, way, tagCount, status, options))
                        return false;
                    ++summary.ways;
                    summary.tags += tagCount;
                    summary.wayNodeReferences += way.nodes.length;
                    deliverWay(handler, way);
                }
                else if (equal(xml.front.name.save, "relation"))
                {
                    OwnedRelation relation;
                    ulong tagCount;
                    if (!parseRelation(xml, relation, tagCount, status, options))
                        return false;
                    ++summary.relations;
                    summary.tags += tagCount;
                    summary.relationMembers += relation.members.length;
                    deliverRelation(handler, relation);
                }
                else
                {
                    setPosition(status, xml.front);
                    status.error = OsmXmlReadError.unsupportedContent;
                    return false;
                }
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
}

/**
 * Transactionally materialize one complete OSM XML document.
 *
 * Failure leaves document at .init. This convenience function intentionally
 * materializes the dataset; use OsmXmlReader.read for bounded streaming.
 */
bool readOsmXmlDocument(
    ByteSource source,
    out OsmXmlDocument document,
    out OsmXmlReadStatus status,
    OsmXmlReadOptions options = OsmXmlReadOptions.init)
    @safe
{
    struct Collector
    {
        OwnedDataset data;

        void node(OwnedNode value) @safe
        {
            data.nodes ~= value;
        }

        void way(OwnedWay value) @safe
        {
            data.ways ~= value;
        }

        void relation(OwnedRelation value) @safe
        {
            data.relations ~= value;
        }
    }

    document = OsmXmlDocument.init;

    Collector collector;
    OsmXmlReadSummary summary;
    OsmXmlReader reader;

    if (!reader.read(source, collector, summary, status, options))
        return false;

    OsmXmlDocument result;
    result.info = summary.info;
    result.data = collector.data;
    document = result;
    return true;
}

private:

void deliverNode(Handler)(ref Handler handler, OwnedNode value) @safe
{
    static if (__traits(compiles, handler.node(value)))
        handler.node(value);
}

void deliverWay(Handler)(ref Handler handler, OwnedWay value) @safe
{
    static if (__traits(compiles, handler.way(value)))
        handler.way(value);
}

void deliverRelation(Handler)(ref Handler handler, OwnedRelation value) @safe
{
    static if (__traits(compiles, handler.relation(value)))
        handler.relation(value);
}

enum size_t defaultMaximumChildren = 1_000_000;
enum size_t defaultDeclarationBytes = 4096;

size_t childLimit(OsmXmlReadOptions options) @safe pure nothrow @nogc
{
    return options.maximumChildrenPerElement == 0
        ? defaultMaximumChildren
        : options.maximumChildrenPerElement;
}

size_t declarationLimit(OsmXmlReadOptions options) @safe pure nothrow @nogc
{
    return options.maximumXmlDeclarationBytes == 0
        ? defaultDeclarationBytes
        : options.maximumXmlDeclarationBytes;
}

void setPosition(Entity)(ref OsmXmlReadStatus status, Entity entity)
{
    status.line = entity.pos.line;
    status.column = entity.pos.col;
}

void setIdentity(
    ref OsmXmlReadStatus status,
    ElementType type,
    OsmId id) @safe pure nothrow @nogc
{
    status.elementType = type;
    status.elementId = id;
    status.hasElementIdentity = true;
}

bool prepareEncoding(
    ByteSource source,
    OsmXmlReadOptions options,
    out ulong startOffset,
    ref OsmXmlReadStatus status)
    @safe
{
    startOffset = 0;

    const probeSize = declarationLimit(options);
    if (probeSize < 4)
    {
        status.error = OsmXmlReadError.resourceLimit;
        return false;
    }

    auto probe = new ubyte[probeSize];
    auto result = source.readSome(
        0,
        probe[],
        ReadLimits(probe.length));

    if (result.error == ReadError.endOfSource)
        return true;

    if (!result.ok)
    {
        status.error = OsmXmlReadError.transportFailure;
        status.transportError = result.error;
        return false;
    }

    const data = probe[0 .. result.bytesRead];

    if (data.length >= 4 &&
        ((data[0] == 0x00 && data[1] == 0x00 &&
          data[2] == 0xFE && data[3] == 0xFF) ||
         (data[0] == 0xFF && data[1] == 0xFE &&
          data[2] == 0x00 && data[3] == 0x00)))
    {
        status.error = OsmXmlReadError.unsupportedEncoding;
        return false;
    }

    if (data.length >= 2 &&
        ((data[0] == 0xFE && data[1] == 0xFF) ||
         (data[0] == 0xFF && data[1] == 0xFE)))
    {
        status.error = OsmXmlReadError.unsupportedEncoding;
        return false;
    }

    if (data.length >= 3 &&
        data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF)
    {
        startOffset = 3;
    }

    if (data.length <= startOffset)
        return true;

    auto text = cast(const(char)[]) data[cast(size_t) startOffset .. $];
    if (!text.startsWith("<?xml"))
        return true;

    const end = indexOf(text, "?>");
    if (end < 0)
    {
        status.error = result.bytesRead == probe.length
            ? OsmXmlReadError.resourceLimit
            : OsmXmlReadError.malformedXml;
        return false;
    }

    const declaration = text[0 .. cast(size_t) end];
    const encodingPos = indexOf(declaration, "encoding");
    if (encodingPos < 0)
        return true;

    size_t i = cast(size_t) encodingPos + "encoding".length;
    skipAsciiSpace(declaration, i);
    if (i >= declaration.length || declaration[i] != '=')
    {
        status.error = OsmXmlReadError.malformedXml;
        return false;
    }

    ++i;
    skipAsciiSpace(declaration, i);
    if (i >= declaration.length ||
        (declaration[i] != '"' && declaration[i] != '\''))
    {
        status.error = OsmXmlReadError.malformedXml;
        return false;
    }

    const quote = declaration[i++];
    const begin = i;
    while (i < declaration.length && declaration[i] != quote)
        ++i;

    if (i == declaration.length)
    {
        status.error = OsmXmlReadError.malformedXml;
        return false;
    }

    if (!asciiEqualIgnoreCase(declaration[begin .. i], "UTF-8"))
    {
        status.error = OsmXmlReadError.unsupportedEncoding;
        return false;
    }

    return true;
}

void skipAsciiSpace(const(char)[] text, ref size_t i)
    @safe pure nothrow @nogc
{
    while (i < text.length)
    {
        final switch (text[i])
        {
            case ' ':
            case '\t':
            case '\r':
            case '\n':
                ++i;
                break;
            default:
                return;
        }
    }
}

bool asciiEqualIgnoreCase(const(char)[] a, string b)
    @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;

    foreach (i; 0 .. a.length)
    {
        char x = a[i];
        char y = b[i];
        if (x >= 'a' && x <= 'z')
            x = cast(char)(x - ('a' - 'A'));
        if (y >= 'a' && y <= 'z')
            y = cast(char)(y - ('a' - 'A'));
        if (x != y)
            return false;
    }
    return true;
}

OwnedBytes ownDecoded(R)(R range)
{
    const value = decodeXML(range);
    return ownBytes(cast(const(ubyte)[]) value);
}

bool parseRootAttributes(Entity)(
    Entity entity,
    ref OsmXmlDocumentInfo info,
    ref OsmXmlReadStatus status)
{
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
            info.hasVersion = true;
            info.versionText = ownBytes(cast(const(ubyte)[]) value);
        }
        else if (equal(attr.name.save, "generator"))
        {
            info.hasGenerator = true;
            info.generator = ownDecoded(attr.value);
        }
        else if (equal(attr.name.save, "copyright"))
        {
            info.hasCopyright = true;
            info.copyrightText = ownDecoded(attr.value);
        }
        else if (equal(attr.name.save, "attribution"))
        {
            info.hasAttribution = true;
            info.attribution = ownDecoded(attr.value);
        }
        else if (equal(attr.name.save, "license"))
        {
            info.hasLicense = true;
            info.license = ownDecoded(attr.value);
        }
        else
        {
            setPosition(status, entity);
            status.error = OsmXmlReadError.unsupportedContent;
            return false;
        }

        attrs.popFront();
    }

    return true;
}

bool parseBounds(R)(
    ref R xml,
    ref OsmXmlDocumentInfo info,
    ref OsmXmlReadStatus status)
{
    auto entity = xml.front;
    bool hasMinLat;
    bool hasMinLon;
    bool hasMaxLat;
    bool hasMaxLon;
    long minLat;
    long minLon;
    long maxLat;
    long maxLon;
    OsmXmlBounds bounds;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        const value = decodeXML(attr.value);

        if (equal(attr.name.save, "minlat"))
        {
            if (!parseCoordinate(value, 90, minLat, status))
                return false;
            hasMinLat = true;
        }
        else if (equal(attr.name.save, "minlon"))
        {
            if (!parseCoordinate(value, 180, minLon, status))
                return false;
            hasMinLon = true;
        }
        else if (equal(attr.name.save, "maxlat"))
        {
            if (!parseCoordinate(value, 90, maxLat, status))
                return false;
            hasMaxLat = true;
        }
        else if (equal(attr.name.save, "maxlon"))
        {
            if (!parseCoordinate(value, 180, maxLon, status))
                return false;
            hasMaxLon = true;
        }
        else if (equal(attr.name.save, "origin"))
        {
            bounds.hasOrigin = true;
            bounds.origin = ownBytes(cast(const(ubyte)[]) value);
        }
        else
        {
            setPosition(status, entity);
            status.error = OsmXmlReadError.unsupportedContent;
            return false;
        }

        attrs.popFront();
    }

    if (!hasMinLat || !hasMinLon || !hasMaxLat || !hasMaxLon)
    {
        setPosition(status, entity);
        status.error = OsmXmlReadError.missingAttribute;
        return false;
    }

    if (minLat > maxLat || minLon > maxLon)
    {
        setPosition(status, entity);
        status.error = OsmXmlReadError.invalidAttribute;
        return false;
    }

    bounds.minimum = LocationView(minLat, minLon);
    bounds.maximum = LocationView(maxLat, maxLon);
    info.bounds ~= bounds;

    return consumeEmpty(xml, "bounds", status);
}

bool parseNode(R)(
    ref R xml,
    out OwnedNode node,
    out ulong tagCount,
    ref OsmXmlReadStatus status,
    OsmXmlReadOptions options)
{
    tagCount = 0;
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
            if (!parseLong(value, node.id))
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
            if (!parseCoordinate(value, 90, lat, status))
                return false;
            hasLat = true;
        }
        else if (equal(attr.name.save, "lon"))
        {
            const value = decodeXML(attr.value);
            if (!parseCoordinate(value, 180, lon, status))
                return false;
            hasLon = true;
        }
        else if (!parseMetadataAttribute(attr, node.metadata, status, entity))
        {
            return false;
        }

        attrs.popFront();
    }

    if (!hasId || !hasLat || !hasLon)
    {
        setPosition(status, entity);
        status.error = OsmXmlReadError.missingAttribute;
        return false;
    }

    setIdentity(status, ElementType.node, node.id);
    node.location = LocationView(lat, lon);

    xml.popFront();
    size_t children;

    while (!xml.empty)
    {
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
        if (!parseTag(xml, tag, status))
            return false;
        node.tags ~= tag;
        ++tagCount;
    }

    status.error = OsmXmlReadError.invalidStructure;
    return false;
}

bool parseWay(R)(
    ref R xml,
    out OwnedWay way,
    out ulong tagCount,
    ref OsmXmlReadStatus status,
    OsmXmlReadOptions options)
{
    tagCount = 0;
    auto entity = xml.front;
    bool hasId;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        if (equal(attr.name.save, "id"))
        {
            const value = decodeXML(attr.value);
            if (!parseLong(value, way.id))
            {
                setPosition(status, entity);
                status.error = OsmXmlReadError.invalidAttribute;
                return false;
            }
            hasId = true;
        }
        else if (!parseMetadataAttribute(attr, way.metadata, status, entity))
        {
            return false;
        }
        attrs.popFront();
    }

    if (!hasId)
    {
        setPosition(status, entity);
        status.error = OsmXmlReadError.missingAttribute;
        return false;
    }

    setIdentity(status, ElementType.way, way.id);
    xml.popFront();
    size_t children;

    while (!xml.empty)
    {
        if (xml.front.type == XmlEntityType.elementEnd &&
            equal(xml.front.name.save, "way"))
        {
            xml.popFront();
            return true;
        }

        if (xml.front.type != XmlEntityType.elementStart)
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

        if (equal(xml.front.name.save, "nd"))
        {
            OwnedWayNode nodeRef;
            if (!parseWayNode(xml, nodeRef, status))
                return false;
            way.nodes ~= nodeRef;
        }
        else if (equal(xml.front.name.save, "tag"))
        {
            OwnedTag tag;
            if (!parseTag(xml, tag, status))
                return false;
            way.tags ~= tag;
            ++tagCount;
        }
        else
        {
            setPosition(status, xml.front);
            status.error = OsmXmlReadError.unsupportedContent;
            return false;
        }
    }

    status.error = OsmXmlReadError.invalidStructure;
    return false;
}

bool parseRelation(R)(
    ref R xml,
    out OwnedRelation relation,
    out ulong tagCount,
    ref OsmXmlReadStatus status,
    OsmXmlReadOptions options)
{
    tagCount = 0;
    auto entity = xml.front;
    bool hasId;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        if (equal(attr.name.save, "id"))
        {
            const value = decodeXML(attr.value);
            if (!parseLong(value, relation.id))
            {
                setPosition(status, entity);
                status.error = OsmXmlReadError.invalidAttribute;
                return false;
            }
            hasId = true;
        }
        else if (!parseMetadataAttribute(attr, relation.metadata, status, entity))
        {
            return false;
        }
        attrs.popFront();
    }

    if (!hasId)
    {
        setPosition(status, entity);
        status.error = OsmXmlReadError.missingAttribute;
        return false;
    }

    setIdentity(status, ElementType.relation, relation.id);
    xml.popFront();
    size_t children;

    while (!xml.empty)
    {
        if (xml.front.type == XmlEntityType.elementEnd &&
            equal(xml.front.name.save, "relation"))
        {
            xml.popFront();
            return true;
        }

        if (xml.front.type != XmlEntityType.elementStart)
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

        if (equal(xml.front.name.save, "member"))
        {
            OwnedRelationMember member;
            if (!parseRelationMember(xml, member, status))
                return false;
            relation.members ~= member;
        }
        else if (equal(xml.front.name.save, "tag"))
        {
            OwnedTag tag;
            if (!parseTag(xml, tag, status))
                return false;
            relation.tags ~= tag;
            ++tagCount;
        }
        else
        {
            setPosition(status, xml.front);
            status.error = OsmXmlReadError.unsupportedContent;
            return false;
        }
    }

    status.error = OsmXmlReadError.invalidStructure;
    return false;
}

bool parseTag(R)(
    ref R xml,
    out OwnedTag tag,
    ref OsmXmlReadStatus status)
{
    auto entity = xml.front;
    bool hasKey;
    bool hasValue;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        if (equal(attr.name.save, "k"))
        {
            tag.key = ownDecoded(attr.value);
            hasKey = true;
        }
        else if (equal(attr.name.save, "v"))
        {
            tag.value = ownDecoded(attr.value);
            hasValue = true;
        }
        else
        {
            setPosition(status, entity);
            status.error = OsmXmlReadError.unsupportedContent;
            return false;
        }
        attrs.popFront();
    }

    if (!hasKey || !hasValue)
    {
        setPosition(status, entity);
        status.error = OsmXmlReadError.missingAttribute;
        return false;
    }

    return consumeEmpty(xml, "tag", status);
}

bool parseWayNode(R)(
    ref R xml,
    out OwnedWayNode nodeRef,
    ref OsmXmlReadStatus status)
{
    auto entity = xml.front;
    bool hasRef;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        if (equal(attr.name.save, "ref"))
        {
            const value = decodeXML(attr.value);
            if (!parseLong(value, nodeRef.id))
            {
                setPosition(status, entity);
                status.error = OsmXmlReadError.invalidAttribute;
                return false;
            }
            hasRef = true;
        }
        else
        {
            setPosition(status, entity);
            status.error = OsmXmlReadError.unsupportedContent;
            return false;
        }
        attrs.popFront();
    }

    if (!hasRef)
    {
        setPosition(status, entity);
        status.error = OsmXmlReadError.missingAttribute;
        return false;
    }

    nodeRef.hasLocation = false;
    return consumeEmpty(xml, "nd", status);
}

bool parseRelationMember(R)(
    ref R xml,
    out OwnedRelationMember member,
    ref OsmXmlReadStatus status)
{
    auto entity = xml.front;
    bool hasType;
    bool hasRef;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;

        if (equal(attr.name.save, "type"))
        {
            const value = decodeXML(attr.value);
            if (value == "node")
                member.type = ElementType.node;
            else if (value == "way")
                member.type = ElementType.way;
            else if (value == "relation")
                member.type = ElementType.relation;
            else
            {
                setPosition(status, entity);
                status.error = OsmXmlReadError.invalidAttribute;
                return false;
            }
            hasType = true;
        }
        else if (equal(attr.name.save, "ref"))
        {
            const value = decodeXML(attr.value);
            if (!parseLong(value, member.id))
            {
                setPosition(status, entity);
                status.error = OsmXmlReadError.invalidAttribute;
                return false;
            }
            hasRef = true;
        }
        else if (equal(attr.name.save, "role"))
        {
            member.role = ownDecoded(attr.value);
        }
        else
        {
            setPosition(status, entity);
            status.error = OsmXmlReadError.unsupportedContent;
            return false;
        }

        attrs.popFront();
    }

    if (!hasType || !hasRef)
    {
        setPosition(status, entity);
        status.error = OsmXmlReadError.missingAttribute;
        return false;
    }

    return consumeEmpty(xml, "member", status);
}

bool parseMetadataAttribute(Attr, Entity)(
    ref Attr attr,
    ref OwnedMetadata metadata,
    ref OsmXmlReadStatus status,
    ref Entity entity)
{
    const value = decodeXML(attr.value);

    if (equal(attr.name.save, "version"))
    {
        int parsed;
        if (!parseInt(value, parsed))
            goto invalid;
        metadata.hasVersion = true;
        metadata.versionNumber = parsed;
        return true;
    }

    if (equal(attr.name.save, "timestamp"))
    {
        long parsed;
        const timestampResult = parseTimestampMilliseconds(value, parsed);
        if (timestampResult == TimestampParse.precisionLoss)
        {
            setPosition(status, entity);
            status.error = OsmXmlReadError.precisionLoss;
            return false;
        }
        if (timestampResult != TimestampParse.ok)
            goto invalid;
        metadata.hasTimestamp = true;
        metadata.timestampMilliseconds = parsed;
        return true;
    }

    if (equal(attr.name.save, "changeset"))
    {
        long parsed;
        if (!parseLong(value, parsed))
            goto invalid;
        metadata.hasChangeset = true;
        metadata.changesetId = parsed;
        return true;
    }

    if (equal(attr.name.save, "uid"))
    {
        int parsed;
        if (!parseInt(value, parsed))
            goto invalid;
        metadata.hasUserId = true;
        metadata.userId = parsed;
        return true;
    }

    if (equal(attr.name.save, "user"))
    {
        metadata.hasUsername = true;
        metadata.username = ownBytes(cast(const(ubyte)[]) value);
        return true;
    }

    if (equal(attr.name.save, "visible"))
    {
        bool parsed;
        if (!parseBoolean(value, parsed))
            goto invalid;
        metadata.hasVisibility = true;
        metadata.visible = parsed;
        return true;
    }

    setPosition(status, entity);
    status.error = OsmXmlReadError.unsupportedContent;
    return false;

invalid:
    setPosition(status, entity);
    status.error = OsmXmlReadError.invalidAttribute;
    return false;
}

bool consumeEmpty(R)(
    ref R xml,
    string name,
    ref OsmXmlReadStatus status)
{
    xml.popFront();

    if (xml.empty ||
        xml.front.type != XmlEntityType.elementEnd ||
        !equal(xml.front.name.save, name))
    {
        if (!xml.empty)
            setPosition(status, xml.front);
        status.error = OsmXmlReadError.invalidStructure;
        return false;
    }

    xml.popFront();
    return true;
}

bool parseLong(string text, out long value)
    @safe pure nothrow @nogc
{
    value = 0;
    if (text.length == 0)
        return false;

    size_t i;
    bool negative;
    if (text[0] == '-' || text[0] == '+')
    {
        negative = text[0] == '-';
        i = 1;
        if (i == text.length)
            return false;
    }

    immutable ulong limit = negative
        ? 9_223_372_036_854_775_808UL
        : 9_223_372_036_854_775_807UL;
    ulong magnitude;

    for (; i < text.length; ++i)
    {
        const c = text[i];
        if (c < '0' || c > '9')
            return false;
        const digit = cast(ulong)(c - '0');
        if (magnitude > (limit - digit) / 10)
            return false;
        magnitude = magnitude * 10 + digit;
    }

    if (negative)
    {
        if (magnitude == 9_223_372_036_854_775_808UL)
            value = long.min;
        else
            value = -cast(long)magnitude;
    }
    else
    {
        value = cast(long)magnitude;
    }

    return true;
}

bool parseInt(string text, out int value)
    @safe pure nothrow @nogc
{
    long parsed;
    if (!parseLong(text, parsed) ||
        parsed < int.min || parsed > int.max)
    {
        value = 0;
        return false;
    }

    value = cast(int)parsed;
    return true;
}

bool parseBoolean(string text, out bool value)
    @safe pure nothrow @nogc
{
    if (text == "true" || text == "1")
    {
        value = true;
        return true;
    }
    if (text == "false" || text == "0")
    {
        value = false;
        return true;
    }
    value = false;
    return false;
}

bool parseCoordinate(
    string text,
    long wholeLimit,
    out long nanodegrees,
    ref OsmXmlReadStatus status)
    @safe pure nothrow @nogc
{
    nanodegrees = 0;
    if (text.length == 0)
    {
        status.error = OsmXmlReadError.invalidAttribute;
        return false;
    }

    size_t i;
    bool negative;
    if (text[0] == '-' || text[0] == '+')
    {
        negative = text[0] == '-';
        i = 1;
        if (i == text.length)
        {
            status.error = OsmXmlReadError.invalidAttribute;
            return false;
        }
    }

    ulong whole;
    bool sawWholeDigit;
    while (i < text.length && text[i] != '.')
    {
        const c = text[i];
        if (c < '0' || c > '9')
        {
            status.error = OsmXmlReadError.invalidAttribute;
            return false;
        }
        sawWholeDigit = true;
        const digit = cast(ulong)(c - '0');
        if (whole > (cast(ulong)wholeLimit - digit) / 10)
        {
            status.error = OsmXmlReadError.invalidAttribute;
            return false;
        }
        whole = whole * 10 + digit;
        ++i;
    }

    if (!sawWholeDigit)
    {
        status.error = OsmXmlReadError.invalidAttribute;
        return false;
    }

    ulong fraction;
    size_t fractionDigits;
    if (i < text.length)
    {
        ++i;
        if (i == text.length)
        {
            status.error = OsmXmlReadError.invalidAttribute;
            return false;
        }

        while (i < text.length)
        {
            const c = text[i++];
            if (c < '0' || c > '9')
            {
                status.error = OsmXmlReadError.invalidAttribute;
                return false;
            }

            if (fractionDigits < 9)
            {
                fraction = fraction * 10 + cast(ulong)(c - '0');
                ++fractionDigits;
            }
            else if (c != '0')
            {
                status.error = OsmXmlReadError.precisionLoss;
                return false;
            }
        }
    }

    while (fractionDigits < 9)
    {
        fraction *= 10;
        ++fractionDigits;
    }

    if (whole > cast(ulong)wholeLimit ||
        (whole == cast(ulong)wholeLimit && fraction != 0))
    {
        status.error = OsmXmlReadError.invalidAttribute;
        return false;
    }

    const magnitude = whole * 1_000_000_000UL + fraction;
    nanodegrees = negative
        ? -cast(long)magnitude
        : cast(long)magnitude;
    return true;
}

enum TimestampParse : ubyte
{
    ok,
    invalid,
    precisionLoss,
}

TimestampParse parseTimestampMilliseconds(string text, out long result) @safe
{
    result = 0;
    if (!hasExplicitTimezone(text))
        return TimestampParse.invalid;

    try
    {
        const parsed = SysTime.fromISOExtString(text, UTC());
        const utc = parsed.toUTC();
        const epoch = SysTime.fromUnixTime(0, UTC());

        const delta = utc.stdTime - epoch.stdTime;
        if (delta % 10_000 != 0)
            return TimestampParse.precisionLoss;

        result = delta / 10_000;
        return TimestampParse.ok;
    }
    catch (DateTimeException)
    {
        return TimestampParse.invalid;
    }
}

bool hasExplicitTimezone(string text)
    @safe pure nothrow @nogc
{
    if (text.length == 0)
        return false;
    if (text[$ - 1] == 'Z' || text[$ - 1] == 'z')
        return true;

    const t = indexOf(text, "T");
    if (t < 0)
        return false;

    for (size_t i = cast(size_t)t + 1; i < text.length; ++i)
    {
        if (text[i] == '+' || text[i] == '-')
            return true;
    }
    return false;
}

unittest
{
    long value;
    assert(parseLong("-9223372036854775808", value) && value == long.min);
    assert(parseLong("9223372036854775807", value) && value == long.max);
    assert(!parseLong("9223372036854775808", value));

    OsmXmlReadStatus status;
    assert(parseCoordinate("48.2081743", 90, value, status));
    assert(value == 48_208_174_300L);

    status = OsmXmlReadStatus.init;
    assert(parseCoordinate("16.3738189000", 180, value, status));
    assert(value == 16_373_818_900L);

    status = OsmXmlReadStatus.init;
    assert(!parseCoordinate("16.3738189001", 180, value, status));
    assert(status.error == OsmXmlReadError.precisionLoss);
}

unittest
{
    long timestamp;
    assert(parseTimestampMilliseconds(
        "2008-09-21T21:37:45Z", timestamp) == TimestampParse.ok);
    assert(timestamp > 1_200_000_000_000L);
}
