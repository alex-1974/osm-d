/**
 * Streaming semantic reader for OSM osmChange 0.6 documents.
 *
 * The XML envelope is decoded with dxml while element payloads reuse the
 * ordinary OSM XML semantic element decoder. Each delivered value is an
 * OwnedChangeEntry; no XML parser entity escapes the codec boundary.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.osmchange.reader;

import dxml.parser :
    XmlEntityType = EntityType,
    XMLParsingException,
    parseXML,
    simpleXML;
import dxml.util : decodeXML;
import osm.io.osmchange.document :
    OsmChangeDocument,
    OsmChangeDocumentInfo;
import osm.io.xml.byte_range :
    XmlCharRange,
    XmlSourceException;
import osm.io.xml.reader :
    OsmXmlReadError,
    OsmXmlReadOptions,
    OsmXmlReadStatus,
    parseSemanticXmlLong,
    parseSemanticXmlMetadataAttribute,
    parseSemanticXmlNode,
    parseSemanticXmlRelation,
    parseSemanticXmlWay,
    prepareSemanticXmlEncoding,
    semanticXmlPosition,
    semanticXmlWhitespace;
import osm.model.change :
    ChangeAction,
    ChangeObjectState,
    OwnedChangeEntry,
    OwnedChangeSequence;
import osm.model.owned :
    OwnedMetadata,
    OwnedNode,
    OwnedRelation,
    OwnedWay,
    ownBytes;
import osm.view.element :
    ElementType,
    OsmId;
import std.algorithm.comparison : equal;
import transport.source :
    ByteSource,
    ReadError;

/** Stable high-level failure category for osmChange reading. */
enum OsmChangeReadError : ubyte
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
    incompleteObject,
    invalidOperation,
}

/** Diagnostic from one osmChange read. */
struct OsmChangeReadStatus
{
    OsmChangeReadError error = OsmChangeReadError.none;
    ReadError transportError = ReadError.none;
    ulong byteOffset;
    int line;
    int column;

    ChangeAction action;
    bool hasAction;

    ElementType elementType;
    OsmId elementId;
    bool hasElementIdentity;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == OsmChangeReadError.none;
    }
}

/** Bounded-reader controls. Zero values select the ordinary XML defaults. */
struct OsmChangeReadOptions
{
    size_t bufferSize;
    size_t maximumChildrenPerElement;
    size_t maximumXmlDeclarationBytes;
}

/** Counts and root metadata from one complete successful osmChange read. */
struct OsmChangeReadSummary
{
    OsmChangeDocumentInfo info;
    ulong entries;
    ulong creates;
    ulong modifies;
    ulong deletes;
}

/**
 * Stateless streaming osmChange reader.
 *
 * Entry callbacks happen in source order. A later document error does not roll
 * back entries already delivered to the handler. Use readOsmChangeDocument
 * when whole-document transactional materialization is required.
 */
struct OsmChangeReader
{
    bool read(Handler)(
        ByteSource source,
        ref Handler handler,
        out OsmChangeReadSummary summary,
        out OsmChangeReadStatus status,
        OsmChangeReadOptions options = OsmChangeReadOptions.init)
        @trusted
    {
        summary = OsmChangeReadSummary.init;
        status = OsmChangeReadStatus.init;

        if (source is null)
        {
            status.error = OsmChangeReadError.transportFailure;
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
                status.error = OsmChangeReadError.invalidStructure;
                return false;
            }

            if (xml.front.type != XmlEntityType.elementStart ||
                !equal(xml.front.name.save, "osmChange"))
            {
                setPosition(status, xml.front);
                status.error = OsmChangeReadError.invalidStructure;
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
                    equal(xml.front.name.save, "osmChange"))
                {
                    xml.popFront();
                    while (!xml.empty && semanticXmlWhitespace(xml.front))
                        xml.popFront();

                    if (!xml.empty)
                    {
                        setPosition(status, xml.front);
                        status.error = OsmChangeReadError.invalidStructure;
                        return false;
                    }

                    return true;
                }

                if (xml.front.type != XmlEntityType.elementStart)
                {
                    setPosition(status, xml.front);
                    status.error = OsmChangeReadError.unsupportedContent;
                    return false;
                }

                ChangeAction action;
                if (equal(xml.front.name.save, "create"))
                    action = ChangeAction.create;
                else if (equal(xml.front.name.save, "modify"))
                    action = ChangeAction.modify;
                else if (equal(xml.front.name.save, "delete"))
                    action = ChangeAction.deleteObject;
                else
                {
                    setPosition(status, xml.front);
                    status.error = OsmChangeReadError.unsupportedContent;
                    return false;
                }

                bool deleteIfUnused;
                if (!parseActionAttributes(
                        xml.front,
                        action,
                        deleteIfUnused,
                        status))
                {
                    return false;
                }

                status.action = action;
                status.hasAction = true;

                const groupName = actionName(action);
                xml.popFront();

                while (!xml.empty)
                {
                    if (semanticXmlWhitespace(xml.front))
                    {
                        xml.popFront();
                        continue;
                    }

                    if (xml.front.type == XmlEntityType.elementEnd &&
                        equal(xml.front.name.save, groupName))
                    {
                        xml.popFront();
                        break;
                    }

                    if (xml.front.type != XmlEntityType.elementStart)
                    {
                        setPosition(status, xml.front);
                        status.error = OsmChangeReadError.unsupportedContent;
                        return false;
                    }

                    OwnedChangeEntry entry;
                    if (!parseEntry(
                            xml,
                            action,
                            deleteIfUnused,
                            entry,
                            status,
                            options))
                    {
                        return false;
                    }

                    ++summary.entries;
                    final switch (action)
                    {
                        case ChangeAction.create:
                            ++summary.creates;
                            break;
                        case ChangeAction.modify:
                            ++summary.modifies;
                            break;
                        case ChangeAction.deleteObject:
                            ++summary.deletes;
                            break;
                    }

                    deliverChange(handler, entry);
                }

                if (xml.empty)
                {
                    status.error = OsmChangeReadError.invalidStructure;
                    return false;
                }
            }

            status.error = OsmChangeReadError.invalidStructure;
            return false;
        }
        catch (XmlSourceException e)
        {
            status.error = OsmChangeReadError.transportFailure;
            status.transportError = e.error;
            status.byteOffset = e.offset;
            return false;
        }
        catch (XMLParsingException e)
        {
            status.error = OsmChangeReadError.malformedXml;
            status.line = e.pos.line;
            status.column = e.pos.col;
            return false;
        }
    }
}

/** Transactionally materialize one complete osmChange document. */
bool readOsmChangeDocument(
    ByteSource source,
    out OsmChangeDocument document,
    out OsmChangeReadStatus status,
    OsmChangeReadOptions options = OsmChangeReadOptions.init)
    @safe
{
    struct Collector
    {
        OwnedChangeSequence changes;

        void change(OwnedChangeEntry value) @safe
        {
            changes.entries ~= value;
        }
    }

    document = OsmChangeDocument.init;

    Collector collector;
    OsmChangeReadSummary summary;
    OsmChangeReader reader;

    if (!reader.read(source, collector, summary, status, options))
        return false;

    OsmChangeDocument result;
    result.info = summary.info;
    result.changes = collector.changes;
    document = result;
    return true;
}

private:

OsmXmlReadOptions toXmlOptions(OsmChangeReadOptions options)
    @safe pure nothrow @nogc
{
    OsmXmlReadOptions result;
    result.bufferSize = options.bufferSize;
    result.maximumChildrenPerElement = options.maximumChildrenPerElement;
    result.maximumXmlDeclarationBytes = options.maximumXmlDeclarationBytes;
    return result;
}

void deliverChange(Handler)(
    ref Handler handler,
    OwnedChangeEntry value) @safe
{
    static if (__traits(compiles, handler.change(value)))
        handler.change(value);
}

string actionName(ChangeAction action)
    @safe pure nothrow @nogc
{
    final switch (action)
    {
        case ChangeAction.create:
            return "create";
        case ChangeAction.modify:
            return "modify";
        case ChangeAction.deleteObject:
            return "delete";
    }
}

void setPosition(Entity)(
    ref OsmChangeReadStatus status,
    Entity entity)
{
    OsmXmlReadStatus xmlStatus;
    semanticXmlPosition(xmlStatus, entity);
    status.line = xmlStatus.line;
    status.column = xmlStatus.column;
}

void setIdentity(
    ref OsmChangeReadStatus status,
    ElementType type,
    OsmId id)
    @safe pure nothrow @nogc
{
    status.elementType = type;
    status.elementId = id;
    status.hasElementIdentity = true;
}

bool parseRootAttributes(Entity)(
    Entity entity,
    ref OsmChangeDocumentInfo info,
    ref OsmChangeReadStatus status)
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
                status.error = OsmChangeReadError.unsupportedVersion;
                return false;
            }

            info.hasVersion = true;
            info.versionText = ownBytes(cast(const(ubyte)[]) value);
            hasVersion = true;
        }
        else if (equal(attr.name.save, "generator"))
        {
            const value = decodeXML(attr.value);
            info.hasGenerator = true;
            info.generator = ownBytes(cast(const(ubyte)[]) value);
        }
        else
        {
            setPosition(status, entity);
            status.error = OsmChangeReadError.unsupportedContent;
            return false;
        }

        attrs.popFront();
    }

    if (!hasVersion)
    {
        setPosition(status, entity);
        status.error = OsmChangeReadError.missingAttribute;
        return false;
    }

    return true;
}

bool parseActionAttributes(Entity)(
    Entity entity,
    ChangeAction action,
    out bool deleteIfUnused,
    ref OsmChangeReadStatus status)
{
    deleteIfUnused = false;
    auto attrs = entity.attributes;

    while (!attrs.empty)
    {
        auto attr = attrs.front;

        if (action == ChangeAction.deleteObject &&
            equal(attr.name.save, "if-unused"))
        {
            const value = decodeXML(attr.value);
            if (value == "true" || value == "1")
                deleteIfUnused = true;
            else if (value == "false" || value == "0")
                deleteIfUnused = false;
            else
            {
                setPosition(status, entity);
                status.error = OsmChangeReadError.invalidAttribute;
                return false;
            }
        }
        else
        {
            setPosition(status, entity);
            status.error = OsmChangeReadError.invalidOperation;
            return false;
        }

        attrs.popFront();
    }

    return true;
}

bool parseEntry(R)(
    ref R xml,
    ChangeAction action,
    bool deleteIfUnused,
    out OwnedChangeEntry entry,
    ref OsmChangeReadStatus status,
    OsmChangeReadOptions options)
{
    if (xml.front.type != XmlEntityType.elementStart)
    {
        setPosition(status, xml.front);
        status.error = OsmChangeReadError.invalidStructure;
        return false;
    }

    ElementType type;
    if (equal(xml.front.name.save, "node"))
        type = ElementType.node;
    else if (equal(xml.front.name.save, "way"))
        type = ElementType.way;
    else if (equal(xml.front.name.save, "relation"))
        type = ElementType.relation;
    else
    {
        setPosition(status, xml.front);
        status.error = OsmChangeReadError.unsupportedContent;
        return false;
    }

    if (action == ChangeAction.deleteObject)
    {
        return parseDeleteEntry(
            xml,
            type,
            deleteIfUnused,
            entry,
            status,
            options);
    }

    if (!parseCompleteEntry(
            xml,
            type,
            action,
            false,
            entry,
            status,
            options))
    {
        if (status.error == OsmChangeReadError.missingAttribute)
            status.error = OsmChangeReadError.incompleteObject;
        return false;
    }

    return true;
}

bool parseCompleteEntry(R)(
    ref R xml,
    ElementType type,
    ChangeAction action,
    bool deleteIfUnused,
    out OwnedChangeEntry entry,
    ref OsmChangeReadStatus status,
    OsmChangeReadOptions options)
{
    OsmXmlReadStatus xmlStatus;
    const xmlOptions = toXmlOptions(options);
    ulong ignoredTags;

    final switch (type)
    {
        case ElementType.node:
        {
            OwnedNode node;
            if (!parseSemanticXmlNode(
                    xml,
                    node,
                    ignoredTags,
                    xmlStatus,
                    xmlOptions))
            {
                mapXmlFailure(xmlStatus, status);
                return false;
            }

            entry = OwnedChangeEntry.fromNode(action, node);
            break;
        }

        case ElementType.way:
        {
            OwnedWay way;
            if (!parseSemanticXmlWay(
                    xml,
                    way,
                    ignoredTags,
                    xmlStatus,
                    xmlOptions))
            {
                mapXmlFailure(xmlStatus, status);
                return false;
            }

            entry = OwnedChangeEntry.fromWay(action, way);
            break;
        }

        case ElementType.relation:
        {
            OwnedRelation relation;
            if (!parseSemanticXmlRelation(
                    xml,
                    relation,
                    ignoredTags,
                    xmlStatus,
                    xmlOptions))
            {
                mapXmlFailure(xmlStatus, status);
                return false;
            }

            entry = OwnedChangeEntry.fromRelation(action, relation);
            break;
        }
    }

    entry.deleteIfUnused = deleteIfUnused;
    setIdentity(status, entry.type, entry.id);

    if (!entry.shapeValid)
    {
        status.error = OsmChangeReadError.invalidOperation;
        return false;
    }

    return true;
}

bool parseDeleteEntry(R)(
    ref R xml,
    ElementType type,
    bool deleteIfUnused,
    out OwnedChangeEntry entry,
    ref OsmChangeReadStatus status,
    OsmChangeReadOptions options)
{
    if (type == ElementType.node)
    {
        bool hasLat;
        bool hasLon;
        auto attrs = xml.front.attributes;

        while (!attrs.empty)
        {
            auto attr = attrs.front;
            if (equal(attr.name.save, "lat"))
                hasLat = true;
            else if (equal(attr.name.save, "lon"))
                hasLon = true;
            attrs.popFront();
        }

        if (hasLat != hasLon)
        {
            setPosition(status, xml.front);
            status.error = OsmChangeReadError.incompleteObject;
            return false;
        }

        if (hasLat)
        {
            return parseCompleteEntry(
                xml,
                type,
                ChangeAction.deleteObject,
                deleteIfUnused,
                entry,
                status,
                options);
        }

        return parseMinimalDelete(
            xml,
            type,
            deleteIfUnused,
            entry,
            status);
    }

    if (elementBodyIsEmpty(xml, type))
    {
        return parseMinimalDelete(
            xml,
            type,
            deleteIfUnused,
            entry,
            status);
    }

    return parseCompleteEntry(
        xml,
        type,
        ChangeAction.deleteObject,
        deleteIfUnused,
        entry,
        status,
        options);
}

bool elementBodyIsEmpty(R)(
    ref R xml,
    ElementType type)
{
    auto probe = xml.save;
    probe.popFront();

    while (!probe.empty && semanticXmlWhitespace(probe.front))
        probe.popFront();

    return !probe.empty &&
           probe.front.type == XmlEntityType.elementEnd &&
           equal(probe.front.name.save, elementName(type));
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

bool parseMinimalDelete(R)(
    ref R xml,
    ElementType type,
    bool deleteIfUnused,
    out OwnedChangeEntry entry,
    ref OsmChangeReadStatus status)
{
    auto entity = xml.front;
    bool hasId;
    OsmId id;
    OwnedMetadata metadata;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;

        if (equal(attr.name.save, "id"))
        {
            const value = decodeXML(attr.value);
            if (!parseSemanticXmlLong(value, id))
            {
                setPosition(status, entity);
                status.error = OsmChangeReadError.invalidAttribute;
                return false;
            }
            hasId = true;
        }
        else
        {
            OsmXmlReadStatus xmlStatus;
            if (!parseSemanticXmlMetadataAttribute(
                    attr,
                    metadata,
                    xmlStatus,
                    entity))
            {
                mapXmlFailure(xmlStatus, status);
                return false;
            }
        }

        attrs.popFront();
    }

    if (!hasId)
    {
        setPosition(status, entity);
        status.error = OsmChangeReadError.missingAttribute;
        return false;
    }

    xml.popFront();
    while (!xml.empty && semanticXmlWhitespace(xml.front))
        xml.popFront();

    if (xml.empty ||
        xml.front.type != XmlEntityType.elementEnd ||
        !equal(xml.front.name.save, elementName(type)))
    {
        if (!xml.empty)
            setPosition(status, xml.front);
        status.error = OsmChangeReadError.incompleteObject;
        return false;
    }

    xml.popFront();

    entry = OwnedChangeEntry.deletion(
        type,
        id,
        metadata,
        deleteIfUnused);
    setIdentity(status, type, id);

    if (!entry.shapeValid)
    {
        status.error = OsmChangeReadError.invalidOperation;
        return false;
    }

    return true;
}

void mapXmlFailure(
    ref const OsmXmlReadStatus xml,
    ref OsmChangeReadStatus status)
    @safe pure nothrow @nogc
{
    status.transportError = xml.transportError;
    status.byteOffset = xml.byteOffset;
    status.line = xml.line;
    status.column = xml.column;
    status.elementType = xml.elementType;
    status.elementId = xml.elementId;
    status.hasElementIdentity = xml.hasElementIdentity;

    switch (xml.error)
    {
        case OsmXmlReadError.none:
            status.error = OsmChangeReadError.none;
            break;
        case OsmXmlReadError.transportFailure:
            status.error = OsmChangeReadError.transportFailure;
            break;
        case OsmXmlReadError.malformedXml:
            status.error = OsmChangeReadError.malformedXml;
            break;
        case OsmXmlReadError.unsupportedEncoding:
            status.error = OsmChangeReadError.unsupportedEncoding;
            break;
        case OsmXmlReadError.unsupportedVersion:
            status.error = OsmChangeReadError.unsupportedVersion;
            break;
        case OsmXmlReadError.unsupportedContent:
            status.error = OsmChangeReadError.unsupportedContent;
            break;
        case OsmXmlReadError.missingAttribute:
            status.error = OsmChangeReadError.missingAttribute;
            break;
        case OsmXmlReadError.invalidAttribute:
            status.error = OsmChangeReadError.invalidAttribute;
            break;
        case OsmXmlReadError.precisionLoss:
            status.error = OsmChangeReadError.precisionLoss;
            break;
        case OsmXmlReadError.resourceLimit:
            status.error = OsmChangeReadError.resourceLimit;
            break;
        case OsmXmlReadError.invalidStructure:
            status.error = OsmChangeReadError.invalidStructure;
            break;
        default:
            status.error = OsmChangeReadError.invalidStructure;
            break;
    }
}

unittest
{
    import transport.source : MemorySource;

    enum xml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" ~
        "<osmChange version=\"0.6\" generator=\"osm-d-test\">" ~
        "<create>" ~
          "<node id=\"-1\" lat=\"48.2\" lon=\"16.3\" changeset=\"7\">" ~
            "<tag k=\"amenity\" v=\"bench\"/>" ~
          "</node>" ~
        "</create>" ~
        "<modify>" ~
          "<way id=\"10\" version=\"3\" changeset=\"7\">" ~
            "<nd ref=\"-1\"/><nd ref=\"2\"/>" ~
          "</way>" ~
        "</modify>" ~
        "<delete if-unused=\"true\">" ~
          "<relation id=\"20\" version=\"2\" changeset=\"7\"/>" ~
        "</delete>" ~
        "</osmChange>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);

    OsmChangeDocument document;
    OsmChangeReadStatus status;
    assert(readOsmChangeDocument(source, document, status));
    assert(status.ok);

    assert(document.changes.entries.length == 3);
    assert(document.changes.entries[0].action == ChangeAction.create);
    assert(document.changes.entries[0].complete);
    assert(document.changes.entries[1].action == ChangeAction.modify);
    assert(document.changes.entries[1].complete);
    assert(document.changes.entries[2].action == ChangeAction.deleteObject);
    assert(!document.changes.entries[2].complete);
    assert(document.changes.entries[2].deleteIfUnused);
    assert(document.changes.entries[2].metadata.hasVersion);
}

unittest
{
    import transport.source : MemorySource;

    {
        enum xml =
            "<osmChange version=\"0.6\"><modify>" ~
            "<node id=\"1\"/></modify></osmChange>";
        auto source = new MemorySource(cast(const(ubyte)[]) xml);
        OsmChangeDocument document;
        OsmChangeReadStatus status;
        assert(!readOsmChangeDocument(source, document, status));
        assert(status.error == OsmChangeReadError.incompleteObject);
    }

    {
        enum xml =
            "<osmChange version=\"0.6\"><modify if-unused=\"true\">" ~
            "</modify></osmChange>";
        auto source = new MemorySource(cast(const(ubyte)[]) xml);
        OsmChangeDocument document;
        OsmChangeReadStatus status;
        assert(!readOsmChangeDocument(source, document, status));
        assert(status.error == OsmChangeReadError.invalidOperation);
    }
}


unittest // committed ordered osmChange fixture
{
    import transport.source : MemorySource;

    enum fixture = import("osmchange/order-and-delete.osc");
    auto source = new MemorySource(cast(const(ubyte)[]) fixture);

    OsmChangeDocument document;
    OsmChangeReadStatus status;
    assert(readOsmChangeDocument(source, document, status));
    assert(status.ok);

    assert(document.changes.entries.length == 5);
    assert(document.changes.entries[0].action == ChangeAction.create);
    assert(document.changes.entries[1].action == ChangeAction.modify);

    assert(document.changes.entries[2].action == ChangeAction.deleteObject);
    assert(document.changes.entries[2].objectState ==
        ChangeObjectState.identityOnly);
    assert(document.changes.entries[2].deleteIfUnused);

    assert(document.changes.entries[3].action == ChangeAction.deleteObject);
    assert(document.changes.entries[3].objectState ==
        ChangeObjectState.complete);
    assert(document.changes.entries[3].deleteIfUnused);
    assert(document.changes.entries[3].type == ElementType.node);

    assert(document.changes.entries[4].action == ChangeAction.create);
}


unittest // deletion metadata is preserved, never fabricated
{
    import transport.source : MemorySource;

    enum xml =
        "<osmChange version=\"0.6\"><delete>" ~
        "<node id=\"77\"/>" ~
        "</delete></osmChange>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);

    OsmChangeDocument document;
    OsmChangeReadStatus status;
    assert(readOsmChangeDocument(source, document, status));
    assert(document.changes.entries.length == 1);

    ref const entry = document.changes.entries[0];
    assert(entry.action == ChangeAction.deleteObject);
    assert(entry.objectState == ChangeObjectState.identityOnly);
    assert(!entry.metadata.hasVersion);
    assert(!entry.metadata.hasChangeset);
}
