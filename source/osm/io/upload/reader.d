/**
 * Bounded reader for OSM API 0.6 diffResult XML responses.
 *
 * The reader uses the existing transport-d/dxml XML boundary and preserves raw
 * UploadResultEntry fields in source order. It deliberately does not infer the
 * originating create/modify/delete action from XML shape; use
 * UploadResultEntry.effectFor with the matching uploaded request entry.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-04
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.upload.reader;

import dxml.parser :
    XmlEntityType = EntityType,
    XMLParsingException,
    parseXML,
    simpleXML;
import dxml.util : decodeXML;
import osm.io.upload.document :
    UploadResultDocument,
    UploadResultDocumentInfo;
import osm.io.xml.byte_range :
    XmlCharRange,
    XmlSourceException;
import osm.io.xml.reader :
    OsmXmlReadError,
    OsmXmlReadOptions,
    OsmXmlReadStatus,
    parseSemanticXmlLong,
    prepareSemanticXmlEncoding,
    semanticXmlPosition,
    semanticXmlWhitespace;
import osm.model.change :
    UploadResult,
    UploadResultEntry;
import osm.model.owned :
    ownBytes;
import osm.view.element :
    ElementType,
    OsmId;
import std.algorithm.comparison : equal;
import transport.source :
    ByteSource,
    ReadError;

/** Stable high-level failure category for diffResult reading. */
enum UploadResultReadError : ubyte
{
    none,
    transportFailure,
    malformedXml,
    unsupportedEncoding,
    unsupportedVersion,
    unsupportedContent,
    missingAttribute,
    invalidAttribute,
    resourceLimit,
    invalidStructure,
}

/** Diagnostic from one diffResult read. */
struct UploadResultReadStatus
{
    UploadResultReadError error = UploadResultReadError.none;
    ReadError transportError = ReadError.none;
    ulong byteOffset;
    int line;
    int column;

    ElementType elementType;
    OsmId oldId;
    bool hasElementIdentity;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == UploadResultReadError.none;
    }
}

/**
 * Bounded-reader controls.
 *
 * Zero values select defaults. bufferSize and maximumXmlDeclarationBytes use
 * the ordinary OSM XML reader defaults. maximumEntries defaults to 100,000,
 * deliberately above the current Editing API changeset limit while still
 * bounding hostile or non-standard responses.
 */
struct UploadResultReadOptions
{
    size_t bufferSize;
    size_t maximumEntries;
    size_t maximumXmlDeclarationBytes;
}

/** Counts and root metadata from one complete successful read. */
struct UploadResultReadSummary
{
    UploadResultDocumentInfo info;
    ulong entries;
    ulong nodes;
    ulong ways;
    ulong relations;
}

/**
 * Stateless streaming diffResult reader.
 *
 * Entry callbacks happen in source order and duplicate type+oldId values are
 * preserved. A later document failure does not roll back entries already
 * delivered to the handler. Use readUploadResult/readUploadResultDocument for
 * transactional materialization.
 */
struct UploadResultReader
{
    bool read(Handler)(
        ByteSource source,
        ref Handler handler,
        out UploadResultReadSummary summary,
        out UploadResultReadStatus status,
        UploadResultReadOptions options = UploadResultReadOptions.init)
        @trusted
    {
        summary = UploadResultReadSummary.init;
        status = UploadResultReadStatus.init;

        if (source is null)
        {
            status.error = UploadResultReadError.transportFailure;
            status.transportError = ReadError.sourceFailure;
            return false;
        }

        OsmXmlReadStatus xmlStatus;
        ulong startOffset;
        if (!prepareSemanticXmlEncoding(
                source,
                toXmlOptions(options),
                startOffset,
                xmlStatus))
        {
            mapXmlFailure(xmlStatus, status);
            return false;
        }

        try
        {
            auto input = XmlCharRange(source, options.bufferSize, startOffset);
            auto xml = parseXML!simpleXML(input);

            if (xml.empty)
            {
                status.error = UploadResultReadError.invalidStructure;
                return false;
            }

            if (xml.front.type != XmlEntityType.elementStart ||
                !equal(xml.front.name.save, "diffResult"))
            {
                setPosition(status, xml.front);
                status.error = UploadResultReadError.invalidStructure;
                return false;
            }

            if (!parseRootAttributes(xml.front, summary.info, status))
                return false;

            xml.popFront();

            while (!xml.empty)
            {
                if (semanticXmlWhitespace(xml.front))
                {
                    xml.popFront();
                    continue;
                }

                if (xml.front.type == XmlEntityType.elementEnd &&
                    equal(xml.front.name.save, "diffResult"))
                {
                    xml.popFront();
                    while (!xml.empty && semanticXmlWhitespace(xml.front))
                        xml.popFront();

                    if (!xml.empty)
                    {
                        setPosition(status, xml.front);
                        status.error = UploadResultReadError.invalidStructure;
                        return false;
                    }

                    return true;
                }

                if (xml.front.type != XmlEntityType.elementStart)
                {
                    setPosition(status, xml.front);
                    status.error = UploadResultReadError.unsupportedContent;
                    return false;
                }

                if (summary.entries >= entryLimit(options))
                {
                    setPosition(status, xml.front);
                    status.error = UploadResultReadError.resourceLimit;
                    return false;
                }

                UploadResultEntry entry;
                if (!parseEntry(xml, entry, status))
                    return false;

                ++summary.entries;
                final switch (entry.type)
                {
                    case ElementType.node:
                        ++summary.nodes;
                        break;
                    case ElementType.way:
                        ++summary.ways;
                        break;
                    case ElementType.relation:
                        ++summary.relations;
                        break;
                }

                deliverEntry(handler, entry);
            }

            status.error = UploadResultReadError.invalidStructure;
            return false;
        }
        catch (XmlSourceException e)
        {
            status.error = UploadResultReadError.transportFailure;
            status.transportError = e.error;
            status.byteOffset = e.offset;
            return false;
        }
        catch (XMLParsingException e)
        {
            status.error = UploadResultReadError.malformedXml;
            status.line = e.pos.line;
            status.column = e.pos.col;
            return false;
        }
    }
}

/** Transactionally materialize one complete diffResult document. */
bool readUploadResultDocument(
    ByteSource source,
    out UploadResultDocument document,
    out UploadResultReadStatus status,
    UploadResultReadOptions options = UploadResultReadOptions.init)
    @safe
{
    struct Collector
    {
        UploadResult result;

        void entry(UploadResultEntry value) @safe
        {
            result.entries ~= value;
        }
    }

    document = UploadResultDocument.init;

    Collector collector;
    UploadResultReadSummary summary;
    UploadResultReader reader;

    if (!reader.read(source, collector, summary, status, options))
        return false;

    UploadResultDocument parsed;
    parsed.info = summary.info;
    parsed.result = collector.result;
    document = parsed;
    return true;
}

/**
 * Transactionally materialize only the format-neutral upload result.
 *
 * Root XML metadata is deliberately discarded by this convenience function.
 * Use readUploadResultDocument when generator/licence envelope metadata matters.
 */
bool readUploadResult(
    ByteSource source,
    out UploadResult result,
    out UploadResultReadStatus status,
    UploadResultReadOptions options = UploadResultReadOptions.init)
    @safe
{
    result = UploadResult.init;

    UploadResultDocument document;
    if (!readUploadResultDocument(source, document, status, options))
        return false;

    result = document.result;
    return true;
}

private:

enum size_t defaultMaximumEntries = 100_000;

size_t entryLimit(UploadResultReadOptions options)
    @safe pure nothrow @nogc
{
    return options.maximumEntries == 0
        ? defaultMaximumEntries
        : options.maximumEntries;
}

OsmXmlReadOptions toXmlOptions(UploadResultReadOptions options)
    @safe pure nothrow @nogc
{
    OsmXmlReadOptions result;
    result.bufferSize = options.bufferSize;
    result.maximumXmlDeclarationBytes = options.maximumXmlDeclarationBytes;
    return result;
}

void deliverEntry(Handler)(
    ref Handler handler,
    UploadResultEntry value) @safe
{
    static if (__traits(compiles, handler.entry(value)))
        handler.entry(value);
}

void setPosition(Entity)(
    ref UploadResultReadStatus status,
    Entity entity)
{
    OsmXmlReadStatus xmlStatus;
    semanticXmlPosition(xmlStatus, entity);
    status.line = xmlStatus.line;
    status.column = xmlStatus.column;
}

void setIdentity(
    ref UploadResultReadStatus status,
    ElementType type,
    OsmId oldId)
    @safe pure nothrow @nogc
{
    status.elementType = type;
    status.oldId = oldId;
    status.hasElementIdentity = true;
}

bool parseRootAttributes(Entity)(
    Entity entity,
    ref UploadResultDocumentInfo info,
    ref UploadResultReadStatus status)
{
    bool hasVersion;
    auto attrs = entity.attributes;

    while (!attrs.empty)
    {
        auto attr = attrs.front;
        const value = decodeXML(attr.value);

        if (equal(attr.name.save, "version"))
        {
            if (value != "0.6")
            {
                setPosition(status, entity);
                status.error = UploadResultReadError.unsupportedVersion;
                return false;
            }

            info.hasVersion = true;
            info.versionText = ownBytes(cast(const(ubyte)[]) value);
            hasVersion = true;
        }
        else if (equal(attr.name.save, "generator"))
        {
            info.hasGenerator = true;
            info.generator = ownBytes(cast(const(ubyte)[]) value);
        }
        else if (equal(attr.name.save, "copyright"))
        {
            info.hasCopyright = true;
            info.copyrightText = ownBytes(cast(const(ubyte)[]) value);
        }
        else if (equal(attr.name.save, "attribution"))
        {
            info.hasAttribution = true;
            info.attribution = ownBytes(cast(const(ubyte)[]) value);
        }
        else if (equal(attr.name.save, "license"))
        {
            info.hasLicense = true;
            info.license = ownBytes(cast(const(ubyte)[]) value);
        }
        else
        {
            setPosition(status, entity);
            status.error = UploadResultReadError.unsupportedContent;
            return false;
        }

        attrs.popFront();
    }

    if (!hasVersion)
    {
        setPosition(status, entity);
        status.error = UploadResultReadError.missingAttribute;
        return false;
    }

    return true;
}

bool parseEntry(R)(
    ref R xml,
    out UploadResultEntry entry,
    ref UploadResultReadStatus status)
{
    auto entity = xml.front;

    ElementType type;
    if (equal(entity.name.save, "node"))
        type = ElementType.node;
    else if (equal(entity.name.save, "way"))
        type = ElementType.way;
    else if (equal(entity.name.save, "relation"))
        type = ElementType.relation;
    else
    {
        setPosition(status, entity);
        status.error = UploadResultReadError.unsupportedContent;
        return false;
    }

    UploadResultEntry parsed;
    parsed.type = type;

    bool hasOldId;
    bool hasNewId;
    bool hasNewVersion;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        const value = decodeXML(attr.value);
        long number;

        if (equal(attr.name.save, "old_id"))
        {
            if (!parseSemanticXmlLong(value, number))
            {
                setPosition(status, entity);
                status.error = UploadResultReadError.invalidAttribute;
                return false;
            }

            parsed.oldId = number;
            hasOldId = true;
        }
        else if (equal(attr.name.save, "new_id"))
        {
            if (!parseSemanticXmlLong(value, number))
            {
                setPosition(status, entity);
                status.error = UploadResultReadError.invalidAttribute;
                return false;
            }

            parsed.hasNewId = true;
            parsed.newId = number;
            hasNewId = true;
        }
        else if (equal(attr.name.save, "new_version"))
        {
            if (!parseSemanticXmlLong(value, number) ||
                number <= 0 ||
                number > int.max)
            {
                setPosition(status, entity);
                status.error = UploadResultReadError.invalidAttribute;
                return false;
            }

            parsed.hasNewVersion = true;
            parsed.newVersion = cast(int) number;
            hasNewVersion = true;
        }
        else
        {
            setPosition(status, entity);
            status.error = UploadResultReadError.unsupportedContent;
            return false;
        }

        attrs.popFront();
    }

    if (!hasOldId)
    {
        setPosition(status, entity);
        status.error = UploadResultReadError.missingAttribute;
        return false;
    }

    setIdentity(status, type, parsed.oldId);

    if (hasNewId != hasNewVersion || !parsed.shapeValid)
    {
        setPosition(status, entity);
        status.error = UploadResultReadError.invalidAttribute;
        return false;
    }

    xml.popFront();

    while (!xml.empty && semanticXmlWhitespace(xml.front))
        xml.popFront();

    if (xml.empty)
    {
        status.error = UploadResultReadError.invalidStructure;
        return false;
    }

    if (xml.front.type != XmlEntityType.elementEnd ||
        !equal(xml.front.name.save, elementName(type)))
    {
        setPosition(status, xml.front);
        status.error = UploadResultReadError.unsupportedContent;
        return false;
    }

    xml.popFront();
    entry = parsed;
    return true;
}

string elementName(ElementType type)
    @safe pure nothrow @nogc
{
    final switch (type)
    {
        case ElementType.node:
            return "node";
        case ElementType.way:
            return "way";
        case ElementType.relation:
            return "relation";
    }
}

void mapXmlFailure(
    ref const OsmXmlReadStatus xml,
    ref UploadResultReadStatus status)
    @safe pure nothrow @nogc
{
    status.transportError = xml.transportError;
    status.byteOffset = xml.byteOffset;
    status.line = xml.line;
    status.column = xml.column;

    switch (xml.error)
    {
        case OsmXmlReadError.none:
            status.error = UploadResultReadError.none;
            break;
        case OsmXmlReadError.transportFailure:
            status.error = UploadResultReadError.transportFailure;
            break;
        case OsmXmlReadError.malformedXml:
            status.error = UploadResultReadError.malformedXml;
            break;
        case OsmXmlReadError.unsupportedEncoding:
            status.error = UploadResultReadError.unsupportedEncoding;
            break;
        case OsmXmlReadError.unsupportedVersion:
            status.error = UploadResultReadError.unsupportedVersion;
            break;
        case OsmXmlReadError.unsupportedContent:
            status.error = UploadResultReadError.unsupportedContent;
            break;
        case OsmXmlReadError.missingAttribute:
            status.error = UploadResultReadError.missingAttribute;
            break;
        case OsmXmlReadError.invalidAttribute:
            status.error = UploadResultReadError.invalidAttribute;
            break;
        case OsmXmlReadError.resourceLimit:
            status.error = UploadResultReadError.resourceLimit;
            break;
        case OsmXmlReadError.invalidStructure:
            status.error = UploadResultReadError.invalidStructure;
            break;
        default:
            status.error = UploadResultReadError.invalidStructure;
            break;
    }
}

unittest // current server-style envelope and create/modify/delete shapes
{
    import transport.source : MemorySource;

    enum xml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" ~
        "<diffResult version=\"0.6\" generator=\"OpenStreetMap Server\" " ~
        "copyright=\"OpenStreetMap and contributors\" " ~
        "attribution=\"https://www.openstreetmap.org/copyright\" " ~
        "license=\"https://opendatacommons.org/licenses/odbl/1-0/\">" ~
        "<node old_id=\"-1\" new_id=\"101\" new_version=\"1\"/>" ~
        "<way old_id=\"22\" new_id=\"22\" new_version=\"8\"/>" ~
        "<relation old_id=\"33\"/>" ~
        "</diffResult>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);

    UploadResultDocument document;
    UploadResultReadStatus status;
    assert(readUploadResultDocument(source, document, status));
    assert(status.ok);

    assert(document.info.hasVersion);
    assert(document.info.versionText == cast(const(ubyte)[])"0.6");
    assert(document.info.hasGenerator);
    assert(document.info.hasCopyright);
    assert(document.info.hasAttribution);
    assert(document.info.hasLicense);

    assert(document.result.entries.length == 3);
    assert(document.result.entries[0].type == ElementType.node);
    assert(document.result.entries[0].oldId == -1);
    assert(document.result.entries[0].newId == 101);
    assert(document.result.entries[0].newVersion == 1);
    assert(document.result.entries[1].type == ElementType.way);
    assert(document.result.entries[1].newVersion == 8);
    assert(document.result.entries[2].type == ElementType.relation);
    assert(!document.result.entries[2].hasNewId);
}

unittest // duplicate placeholder identities are preserved in source order
{
    import transport.source : MemorySource;

    enum xml =
        "<diffResult version=\"0.6\">" ~
        "<node old_id=\"-1\" new_id=\"101\" new_version=\"1\"/>" ~
        "<node old_id=\"-1\" new_id=\"101\" new_version=\"2\"/>" ~
        "<node old_id=\"-1\"/>" ~
        "</diffResult>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    UploadResult result;
    UploadResultReadStatus status;

    assert(readUploadResult(source, result, status));
    assert(result.entries.length == 3);
    assert(result.entries[0].oldId == -1);
    assert(result.entries[0].newVersion == 1);
    assert(result.entries[1].oldId == -1);
    assert(result.entries[1].newVersion == 2);
    assert(result.entries[2].oldId == -1);
    assert(!result.entries[2].hasNewId);
}

unittest // malformed and bounded inputs fail explicitly
{
    import transport.source : MemorySource;

    {
        enum xml =
            "<diffResult version=\"0.6\">" ~
            "<node old_id=\"1\" new_id=\"1\"/>" ~
            "</diffResult>";
        auto source = new MemorySource(cast(const(ubyte)[]) xml);
        UploadResult result;
        UploadResultReadStatus status;
        assert(!readUploadResult(source, result, status));
        assert(result.empty);
        assert(status.error == UploadResultReadError.invalidAttribute);
    }

    {
        enum xml =
            "<diffResult version=\"0.7\"></diffResult>";
        auto source = new MemorySource(cast(const(ubyte)[]) xml);
        UploadResult result;
        UploadResultReadStatus status;
        assert(!readUploadResult(source, result, status));
        assert(status.error == UploadResultReadError.unsupportedVersion);
    }

    {
        enum xml =
            "<diffResult version=\"0.6\">" ~
            "<node old_id=\"1\"/><way old_id=\"2\"/>" ~
            "</diffResult>";
        auto source = new MemorySource(cast(const(ubyte)[]) xml);
        UploadResult result;
        UploadResultReadStatus status;
        UploadResultReadOptions options;
        options.maximumEntries = 1;
        assert(!readUploadResult(source, result, status, options));
        assert(result.empty);
        assert(status.error == UploadResultReadError.resourceLimit);
    }

    {
        enum xml =
            "<diffResult version=\"0.6\" extra=\"x\"></diffResult>";
        auto source = new MemorySource(cast(const(ubyte)[]) xml);
        UploadResult result;
        UploadResultReadStatus status;
        assert(!readUploadResult(source, result, status));
        assert(status.error == UploadResultReadError.unsupportedContent);
    }
}
