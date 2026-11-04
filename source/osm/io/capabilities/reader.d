/**
 * Bounded XML reader for the editing-relevant OSM API capabilities projection.
 *
 * The reader intentionally extracts only the server policy required by osm-d
 * edit/upload consumers. Unrelated capability families are boundedly skipped;
 * they are not reinterpreted as upload limits.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-04
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.capabilities.reader;

import dxml.parser :
    XmlEntityType = EntityType,
    XMLParsingException,
    parseXML,
    simpleXML;
import dxml.util : decodeXML;
import osm.io.capabilities.document :
    ApiCapabilitiesDocumentInfo,
    ApiServiceState,
    EditingApiCapabilities,
    EditingApiCapabilitiesDocument;
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
import osm.model.owned : ownBytes;
import std.algorithm.comparison : equal;
import transport.source :
    ByteSource,
    ReadError;

/** Stable failure category for capability discovery. */
enum ApiCapabilitiesReadError : ubyte
{
    none,
    transportFailure,
    malformedXml,
    unsupportedEncoding,
    unsupportedVersion,
    missingCapability,
    invalidAttribute,
    resourceLimit,
    invalidStructure,
}

/** Diagnostic from one capabilities read. */
struct ApiCapabilitiesReadStatus
{
    ApiCapabilitiesReadError error = ApiCapabilitiesReadError.none;
    ReadError transportError = ReadError.none;
    ulong byteOffset;
    int line;
    int column;

    /**
     * Whether no capability-read error has been recorded.
     *
     * Returns:
     *   true when error is ApiCapabilitiesReadError.none.
     */
    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == ApiCapabilitiesReadError.none;
    }
}

/**
 * Bounded reader controls.
 *
 * Zero selects defaults. maximumIgnoredXmlEvents defaults to 10,000 and bounds
 * unrelated/future capability subtrees that this editing projection skips.
 */
struct ApiCapabilitiesReadOptions
{
    size_t bufferSize;
    size_t maximumXmlDeclarationBytes;
    size_t maximumIgnoredXmlEvents;
}

/**
 * Stateless transactional reader for one capabilities document.
 */
struct ApiCapabilitiesReader
{
    /**
     * Parse one Editing API capabilities XML document.
     *
     * Params:
     *   source = Byte source containing one capabilities XML document.
     *   document = Receives the projected editing/upload capabilities on
     *              complete success.
     *   status = Receives explicit transport/XML/projection failure details.
     *   options = Optional parser/resource limits; zero fields select defaults.
     *
     * Returns:
     *   true only after the complete document has been parsed and the required
     *   editing/upload projection is present. On failure document remains
     *   at .init.
     *
     * Safety:
     *   The trusted boundary contains dxml parser ranges inside this
     *   synchronous call. No parser entity/range escapes; the returned document
     *   owns the projected byte strings and value data.
     */
    bool read(
        ByteSource source,
        out EditingApiCapabilitiesDocument document,
        out ApiCapabilitiesReadStatus status,
        ApiCapabilitiesReadOptions options = ApiCapabilitiesReadOptions.init)
        @trusted
    {
        document = EditingApiCapabilitiesDocument.init;
        status = ApiCapabilitiesReadStatus.init;

        if (source is null)
        {
            status.error = ApiCapabilitiesReadError.transportFailure;
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

            if (xml.empty ||
                xml.front.type != XmlEntityType.elementStart ||
                !equal(xml.front.name.save, "osm"))
            {
                if (!xml.empty)
                    setPosition(status, xml.front);
                status.error = ApiCapabilitiesReadError.invalidStructure;
                return false;
            }

            EditingApiCapabilitiesDocument parsed;
            if (!parseRootAttributes(xml.front, parsed.info, status))
                return false;

            xml.popFront();

            bool seenApi;
            size_t ignoredEvents;

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

                    if (!xml.empty || !seenApi)
                    {
                        if (!xml.empty)
                            setPosition(status, xml.front);
                        status.error = ApiCapabilitiesReadError.invalidStructure;
                        return false;
                    }

                    if (!requiredProjectionPresent(parsed.capabilities))
                    {
                        status.error = ApiCapabilitiesReadError.missingCapability;
                        return false;
                    }

                    document = parsed;
                    return true;
                }

                if (xml.front.type != XmlEntityType.elementStart)
                {
                    setPosition(status, xml.front);
                    status.error = ApiCapabilitiesReadError.invalidStructure;
                    return false;
                }

                if (equal(xml.front.name.save, "api"))
                {
                    if (seenApi)
                    {
                        setPosition(status, xml.front);
                        status.error = ApiCapabilitiesReadError.invalidStructure;
                        return false;
                    }

                    if (!parseApi(
                            xml,
                            parsed.capabilities,
                            ignoredEvents,
                            status,
                            options))
                        return false;

                    seenApi = true;
                    continue;
                }

                // policy and future unrelated root siblings are explicitly
                // outside the editing/upload projection.
                if (!skipElement(
                        xml,
                        ignoredEvents,
                        status,
                        options))
                    return false;
            }

            status.error = ApiCapabilitiesReadError.invalidStructure;
            return false;
        }
        catch (XmlSourceException e)
        {
            status.error = ApiCapabilitiesReadError.transportFailure;
            status.transportError = e.error;
            status.byteOffset = e.offset;
            return false;
        }
        catch (XMLParsingException e)
        {
            status.error = ApiCapabilitiesReadError.malformedXml;
            status.line = e.pos.line;
            status.column = e.pos.col;
            return false;
        }
    }
}

/**
 * Transactionally read one editing-capability projection.
 *
 * Params:
 *   source = Byte source containing one capabilities XML document.
 *   document = Receives root metadata and editing/upload capabilities.
 *   status = Receives explicit failure details.
 *   options = Optional parser/resource limits; zero fields select defaults.
 *
 * Returns:
 *   true on complete success. On failure document remains at .init.
 */
bool readEditingApiCapabilities(
    ByteSource source,
    out EditingApiCapabilitiesDocument document,
    out ApiCapabilitiesReadStatus status,
    ApiCapabilitiesReadOptions options = ApiCapabilitiesReadOptions.init)
    @safe
{
    ApiCapabilitiesReader reader;
    return reader.read(source, document, status, options);
}

private:

enum size_t defaultMaximumIgnoredXmlEvents = 10_000;

size_t ignoredEventLimit(ApiCapabilitiesReadOptions options)
    @safe pure nothrow @nogc
{
    return options.maximumIgnoredXmlEvents == 0
        ? defaultMaximumIgnoredXmlEvents
        : options.maximumIgnoredXmlEvents;
}

OsmXmlReadOptions toXmlOptions(ApiCapabilitiesReadOptions options)
    @safe pure nothrow @nogc
{
    OsmXmlReadOptions result;
    result.bufferSize = options.bufferSize;
    result.maximumXmlDeclarationBytes = options.maximumXmlDeclarationBytes;
    return result;
}

void setPosition(Entity)(
    ref ApiCapabilitiesReadStatus status,
    Entity entity)
{
    OsmXmlReadStatus xmlStatus;
    semanticXmlPosition(xmlStatus, entity);
    status.line = xmlStatus.line;
    status.column = xmlStatus.column;
}

bool parseRootAttributes(Entity)(
    Entity entity,
    ref ApiCapabilitiesDocumentInfo info,
    ref ApiCapabilitiesReadStatus status)
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
                status.error = ApiCapabilitiesReadError.unsupportedVersion;
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
        // Other root attributes are unrelated to this explicit projection and
        // are tolerated for forward compatibility.

        attrs.popFront();
    }

    if (!hasVersion)
    {
        setPosition(status, entity);
        status.error = ApiCapabilitiesReadError.missingCapability;
        return false;
    }

    return true;
}

bool parseApi(R)(
    ref R xml,
    ref EditingApiCapabilities result,
    ref size_t ignoredEvents,
    ref ApiCapabilitiesReadStatus status,
    ApiCapabilitiesReadOptions options)
{
    // The <api> wrapper currently has no attributes relevant to the projection.
    xml.popFront();

    bool seenVersion;
    bool seenWayNodes;
    bool seenRelationMembers;
    bool seenChangesets;
    bool seenTimeout;
    bool seenStatus;

    while (!xml.empty)
    {
        if (semanticXmlWhitespace(xml.front))
        {
            xml.popFront();
            continue;
        }

        if (xml.front.type == XmlEntityType.elementEnd &&
            equal(xml.front.name.save, "api"))
        {
            xml.popFront();
            return true;
        }

        if (xml.front.type != XmlEntityType.elementStart)
        {
            setPosition(status, xml.front);
            status.error = ApiCapabilitiesReadError.invalidStructure;
            return false;
        }

        if (equal(xml.front.name.save, "version"))
        {
            if (seenVersion)
            {
                setPosition(status, xml.front);
                status.error = ApiCapabilitiesReadError.invalidStructure;
                return false;
            }
            if (!parseVersion(xml, result, status))
                return false;
            seenVersion = true;
        }
        else if (equal(xml.front.name.save, "waynodes"))
        {
            if (seenWayNodes)
            {
                setPosition(status, xml.front);
                status.error = ApiCapabilitiesReadError.invalidStructure;
                return false;
            }
            if (!parseLimitElement(
                    xml,
                    "waynodes",
                    "maximum",
                    result.uploadLimits.maximumWayNodes,
                    status))
                return false;
            seenWayNodes = true;
        }
        else if (equal(xml.front.name.save, "relationmembers"))
        {
            if (seenRelationMembers)
            {
                setPosition(status, xml.front);
                status.error = ApiCapabilitiesReadError.invalidStructure;
                return false;
            }
            if (!parseLimitElement(
                    xml,
                    "relationmembers",
                    "maximum",
                    result.uploadLimits.maximumRelationMembers,
                    status))
                return false;
            seenRelationMembers = true;
        }
        else if (equal(xml.front.name.save, "changesets"))
        {
            if (seenChangesets)
            {
                setPosition(status, xml.front);
                status.error = ApiCapabilitiesReadError.invalidStructure;
                return false;
            }
            if (!parseLimitElement(
                    xml,
                    "changesets",
                    "maximum_elements",
                    result.uploadLimits.maximumChangesetElements,
                    status))
                return false;
            seenChangesets = true;
        }
        else if (equal(xml.front.name.save, "timeout"))
        {
            if (seenTimeout)
            {
                setPosition(status, xml.front);
                status.error = ApiCapabilitiesReadError.invalidStructure;
                return false;
            }
            if (!parseTimeout(xml, result, status))
                return false;
            seenTimeout = true;
        }
        else if (equal(xml.front.name.save, "status"))
        {
            if (seenStatus)
            {
                setPosition(status, xml.front);
                status.error = ApiCapabilitiesReadError.invalidStructure;
                return false;
            }
            if (!parseStatus(xml, result, status))
                return false;
            seenStatus = true;
        }
        else
        {
            // area/note_area/tracepoints/notes and future unrelated capability
            // families are not upload-validation semantics.
            if (!skipElement(
                    xml,
                    ignoredEvents,
                    status,
                    options))
                return false;
        }
    }

    status.error = ApiCapabilitiesReadError.invalidStructure;
    return false;
}

bool parseVersion(R)(
    ref R xml,
    ref EditingApiCapabilities result,
    ref ApiCapabilitiesReadStatus status)
{
    auto entity = xml.front;
    bool hasMinimum;
    bool hasMaximum;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        const value = decodeXML(attr.value);

        if (equal(attr.name.save, "minimum"))
        {
            if (value.length == 0)
            {
                setPosition(status, entity);
                status.error = ApiCapabilitiesReadError.invalidAttribute;
                return false;
            }
            result.hasMinimumVersion = true;
            result.minimumVersion = ownBytes(cast(const(ubyte)[]) value);
            hasMinimum = true;
        }
        else if (equal(attr.name.save, "maximum"))
        {
            if (value.length == 0)
            {
                setPosition(status, entity);
                status.error = ApiCapabilitiesReadError.invalidAttribute;
                return false;
            }
            result.hasMaximumVersion = true;
            result.maximumVersion = ownBytes(cast(const(ubyte)[]) value);
            hasMaximum = true;
        }
        // Extra version metadata is unrelated to the current projection.
        attrs.popFront();
    }

    if (!hasMinimum || !hasMaximum)
    {
        setPosition(status, entity);
        status.error = ApiCapabilitiesReadError.missingCapability;
        return false;
    }

    return consumeEmptyElement(xml, "version", status);
}

bool parseLimitElement(R)(
    ref R xml,
    string elementName,
    string attributeName,
    out size_t value,
    ref ApiCapabilitiesReadStatus status)
{
    auto entity = xml.front;
    bool found;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        if (equal(attr.name.save, attributeName))
        {
            const text = decodeXML(attr.value);
            long parsed;
            if (!parseSemanticXmlLong(text, parsed) ||
                parsed <= 0 ||
                cast(ulong) parsed > cast(ulong) size_t.max)
            {
                setPosition(status, entity);
                status.error = ApiCapabilitiesReadError.invalidAttribute;
                return false;
            }

            value = cast(size_t) parsed;
            found = true;
        }
        // Query limits and future attributes are outside this projection.
        attrs.popFront();
    }

    if (!found)
    {
        setPosition(status, entity);
        status.error = ApiCapabilitiesReadError.missingCapability;
        return false;
    }

    xml.popFront();
    while (!xml.empty && semanticXmlWhitespace(xml.front))
        xml.popFront();

    if (xml.empty ||
        xml.front.type != XmlEntityType.elementEnd ||
        !equal(xml.front.name.save, elementName))
    {
        if (!xml.empty)
            setPosition(status, xml.front);
        status.error = ApiCapabilitiesReadError.invalidStructure;
        return false;
    }

    xml.popFront();
    return true;
}

bool parseTimeout(R)(
    ref R xml,
    ref EditingApiCapabilities result,
    ref ApiCapabilitiesReadStatus status)
{
    size_t seconds;
    if (!parseLimitElement(
            xml, "timeout", "seconds", seconds, status))
        return false;

    result.hasTimeout = true;
    result.timeoutSeconds = seconds;
    return true;
}

bool parseStatus(R)(
    ref R xml,
    ref EditingApiCapabilities result,
    ref ApiCapabilitiesReadStatus status)
{
    auto entity = xml.front;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        const value = decodeXML(attr.value);
        ApiServiceState state;

        if (equal(attr.name.save, "database"))
        {
            if (!parseServiceState(value, state))
            {
                setPosition(status, entity);
                status.error = ApiCapabilitiesReadError.invalidAttribute;
                return false;
            }
            result.hasDatabaseState = true;
            result.databaseState = state;
        }
        else if (equal(attr.name.save, "api"))
        {
            if (!parseServiceState(value, state))
            {
                setPosition(status, entity);
                status.error = ApiCapabilitiesReadError.invalidAttribute;
                return false;
            }
            result.hasApiState = true;
            result.apiState = state;
        }
        else if (equal(attr.name.save, "gpx"))
        {
            if (!parseServiceState(value, state))
            {
                setPosition(status, entity);
                status.error = ApiCapabilitiesReadError.invalidAttribute;
                return false;
            }
            result.hasGpxState = true;
            result.gpxState = state;
        }
        attrs.popFront();
    }

    return consumeEmptyElement(xml, "status", status);
}

bool parseServiceState(
    string text,
    out ApiServiceState state)
    @safe pure nothrow @nogc
{
    if (text == "online")
    {
        state = ApiServiceState.online;
        return true;
    }
    if (text == "readonly")
    {
        state = ApiServiceState.readonly;
        return true;
    }
    if (text == "offline")
    {
        state = ApiServiceState.offline;
        return true;
    }

    state = ApiServiceState.unknown;
    return false;
}

bool consumeEmptyElement(R)(
    ref R xml,
    string name,
    ref ApiCapabilitiesReadStatus status)
{
    xml.popFront();
    while (!xml.empty && semanticXmlWhitespace(xml.front))
        xml.popFront();

    if (xml.empty ||
        xml.front.type != XmlEntityType.elementEnd ||
        !equal(xml.front.name.save, name))
    {
        if (!xml.empty)
            setPosition(status, xml.front);
        status.error = ApiCapabilitiesReadError.invalidStructure;
        return false;
    }

    xml.popFront();
    return true;
}

bool skipElement(R)(
    ref R xml,
    ref size_t ignoredEvents,
    ref ApiCapabilitiesReadStatus status,
    ApiCapabilitiesReadOptions options)
{
    if (xml.empty || xml.front.type != XmlEntityType.elementStart)
    {
        if (!xml.empty)
            setPosition(status, xml.front);
        status.error = ApiCapabilitiesReadError.invalidStructure;
        return false;
    }

    size_t depth;

    while (!xml.empty)
    {
        if (ignoredEvents >= ignoredEventLimit(options))
        {
            setPosition(status, xml.front);
            status.error = ApiCapabilitiesReadError.resourceLimit;
            return false;
        }
        ++ignoredEvents;

        if (xml.front.type == XmlEntityType.elementStart)
        {
            ++depth;
        }
        else if (xml.front.type == XmlEntityType.elementEnd)
        {
            if (depth == 0)
            {
                setPosition(status, xml.front);
                status.error = ApiCapabilitiesReadError.invalidStructure;
                return false;
            }

            --depth;
            xml.popFront();
            if (depth == 0)
                return true;
            continue;
        }

        xml.popFront();
    }

    status.error = ApiCapabilitiesReadError.invalidStructure;
    return false;
}

bool requiredProjectionPresent(EditingApiCapabilities value)
    @safe pure nothrow @nogc
{
    return value.hasMinimumVersion &&
           value.hasMaximumVersion &&
           value.uploadLimits.maximumWayNodes > 0 &&
           value.uploadLimits.maximumRelationMembers > 0 &&
           value.uploadLimits.maximumChangesetElements > 0;
}

void mapXmlFailure(
    ref const OsmXmlReadStatus xml,
    ref ApiCapabilitiesReadStatus status)
    @safe pure nothrow @nogc
{
    status.transportError = xml.transportError;
    status.byteOffset = xml.byteOffset;
    status.line = xml.line;
    status.column = xml.column;

    switch (xml.error)
    {
        case OsmXmlReadError.none:
            status.error = ApiCapabilitiesReadError.none;
            break;
        case OsmXmlReadError.transportFailure:
            status.error = ApiCapabilitiesReadError.transportFailure;
            break;
        case OsmXmlReadError.malformedXml:
            status.error = ApiCapabilitiesReadError.malformedXml;
            break;
        case OsmXmlReadError.unsupportedEncoding:
            status.error = ApiCapabilitiesReadError.unsupportedEncoding;
            break;
        case OsmXmlReadError.resourceLimit:
            status.error = ApiCapabilitiesReadError.resourceLimit;
            break;
        case OsmXmlReadError.unsupportedVersion:
            status.error = ApiCapabilitiesReadError.unsupportedVersion;
            break;
        default:
            status.error = ApiCapabilitiesReadError.invalidStructure;
            break;
    }
}

unittest // current Rails capability projection
{
    import transport.source : MemorySource;

    enum xml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" ~
        "<osm version=\"0.6\" generator=\"OpenStreetMap server\" " ~
        "copyright=\"OpenStreetMap and contributors\" " ~
        "attribution=\"https://www.openstreetmap.org/copyright\" " ~
        "license=\"https://opendatacommons.org/licenses/odbl/1-0/\">" ~
        "<api>" ~
        "<version minimum=\"0.6\" maximum=\"0.6\"/>" ~
        "<area maximum=\"0.25\"/>" ~
        "<note_area maximum=\"25\"/>" ~
        "<tracepoints per_page=\"5000\"/>" ~
        "<waynodes maximum=\"2000\"/>" ~
        "<relationmembers maximum=\"32000\"/>" ~
        "<changesets maximum_elements=\"10000\" default_query_limit=\"100\" maximum_query_limit=\"100\"/>" ~
        "<notes default_query_limit=\"100\" maximum_query_limit=\"10000\"/>" ~
        "<timeout seconds=\"300\"/>" ~
        "<status database=\"online\" api=\"online\" gpx=\"online\"/>" ~
        "</api>" ~
        "<policy><imagery><blacklist regex=\"example\"/></imagery></policy>" ~
        "</osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    EditingApiCapabilitiesDocument document;
    ApiCapabilitiesReadStatus status;

    assert(readEditingApiCapabilities(source, document, status));
    assert(status.ok);
    assert(document.info.hasVersion);
    assert(document.info.versionText == cast(const(ubyte)[])"0.6");
    assert(document.info.hasGenerator);
    assert(document.capabilities.minimumVersion == cast(const(ubyte)[])"0.6");
    assert(document.capabilities.maximumVersion == cast(const(ubyte)[])"0.6");

    const profile = document.capabilities.validationProfile;
    assert(profile.maximumWayNodes == 2_000);
    assert(profile.maximumRelationMembers == 32_000);
    assert(profile.maximumChangesetElements == 10_000);

    assert(document.capabilities.hasTimeout);
    assert(document.capabilities.timeoutSeconds == 300);
    assert(document.capabilities.apiState == ApiServiceState.online);
    assert(document.capabilities.databaseState == ApiServiceState.online);
    assert(document.capabilities.gpxState == ApiServiceState.online);
}

unittest // service states and future unrelated capability siblings
{
    import transport.source : MemorySource;

    enum xml =
        "<osm version=\"0.6\">" ~
        "<future_root><nested value=\"1\"/></future_root>" ~
        "<api>" ~
        "<version minimum=\"0.6\" maximum=\"0.6\" future=\"x\"/>" ~
        "<future_limit value=\"123\"><nested/></future_limit>" ~
        "<waynodes maximum=\"3000\" extra=\"x\"/>" ~
        "<relationmembers maximum=\"40000\"/>" ~
        "<changesets maximum_elements=\"12000\" maximum_query_limit=\"50\"/>" ~
        "<status database=\"readonly\" api=\"offline\" gpx=\"online\" future=\"x\"/>" ~
        "</api>" ~
        "</osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    EditingApiCapabilitiesDocument document;
    ApiCapabilitiesReadStatus status;

    assert(readEditingApiCapabilities(source, document, status));
    assert(document.capabilities.uploadLimits.maximumWayNodes == 3_000);
    assert(document.capabilities.uploadLimits.maximumRelationMembers == 40_000);
    assert(document.capabilities.uploadLimits.maximumChangesetElements == 12_000);
    assert(document.capabilities.databaseState == ApiServiceState.readonly);
    assert(document.capabilities.apiState == ApiServiceState.offline);
}

unittest // malformed projected values fail transactionally
{
    import transport.source : MemorySource;

    {
        enum xml =
            "<osm version=\"0.6\"><api>" ~
            "<version minimum=\"0.6\" maximum=\"0.6\"/>" ~
            "<waynodes maximum=\"0\"/>" ~
            "<relationmembers maximum=\"32000\"/>" ~
            "<changesets maximum_elements=\"10000\"/>" ~
            "</api></osm>";

        auto source = new MemorySource(cast(const(ubyte)[]) xml);
        EditingApiCapabilitiesDocument document;
        ApiCapabilitiesReadStatus status;
        assert(!readEditingApiCapabilities(source, document, status));
        assert(status.error == ApiCapabilitiesReadError.invalidAttribute);
        assert(document == EditingApiCapabilitiesDocument.init);
    }

    {
        enum xml =
            "<osm version=\"0.6\"><api>" ~
            "<version minimum=\"0.6\" maximum=\"0.6\"/>" ~
            "<waynodes maximum=\"2000\"/>" ~
            "<relationmembers/>" ~
            "<changesets maximum_elements=\"10000\"/>" ~
            "</api></osm>";

        auto source = new MemorySource(cast(const(ubyte)[]) xml);
        EditingApiCapabilitiesDocument document;
        ApiCapabilitiesReadStatus status;
        assert(!readEditingApiCapabilities(source, document, status));
        assert(status.error == ApiCapabilitiesReadError.missingCapability);
        assert(document == EditingApiCapabilitiesDocument.init);
    }

    {
        enum xml =
            "<osm version=\"0.7\"><api></api></osm>";
        auto source = new MemorySource(cast(const(ubyte)[]) xml);
        EditingApiCapabilitiesDocument document;
        ApiCapabilitiesReadStatus status;
        assert(!readEditingApiCapabilities(source, document, status));
        assert(status.error == ApiCapabilitiesReadError.unsupportedVersion);
    }
}

unittest // ignored subtree work is bounded
{
    import transport.source : MemorySource;

    enum xml =
        "<osm version=\"0.6\">" ~
        "<future><a><b/></a></future>" ~
        "<api>" ~
        "<version minimum=\"0.6\" maximum=\"0.6\"/>" ~
        "<waynodes maximum=\"2000\"/>" ~
        "<relationmembers maximum=\"32000\"/>" ~
        "<changesets maximum_elements=\"10000\"/>" ~
        "</api></osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    EditingApiCapabilitiesDocument document;
    ApiCapabilitiesReadStatus status;
    ApiCapabilitiesReadOptions options;
    options.maximumIgnoredXmlEvents = 2;

    assert(!readEditingApiCapabilities(source, document, status, options));
    assert(status.error == ApiCapabilitiesReadError.resourceLimit);
}


unittest // duplicate projected capability is an explicit structure error
{
    import transport.source : MemorySource;

    enum xml =
        "<osm version=\"0.6\"><api>" ~
        "<version minimum=\"0.6\" maximum=\"0.6\"/>" ~
        "<waynodes maximum=\"2000\"/>" ~
        "<waynodes maximum=\"3000\"/>" ~
        "<relationmembers maximum=\"32000\"/>" ~
        "<changesets maximum_elements=\"10000\"/>" ~
        "</api></osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    EditingApiCapabilitiesDocument document;
    ApiCapabilitiesReadStatus status;

    assert(!readEditingApiCapabilities(source, document, status));
    assert(status.error == ApiCapabilitiesReadError.invalidStructure);
}


unittest // invalid service state and malformed XML fail explicitly
{
    import transport.source : MemorySource;

    {
        enum xml =
            "<osm version=\"0.6\"><api>" ~
            "<version minimum=\"0.6\" maximum=\"0.6\"/>" ~
            "<waynodes maximum=\"2000\"/>" ~
            "<relationmembers maximum=\"32000\"/>" ~
            "<changesets maximum_elements=\"10000\"/>" ~
            "<status database=\"online\" api=\"maintenance\" gpx=\"online\"/>" ~
            "</api></osm>";

        auto source = new MemorySource(cast(const(ubyte)[]) xml);
        EditingApiCapabilitiesDocument document;
        ApiCapabilitiesReadStatus status;

        assert(!readEditingApiCapabilities(source, document, status));
        assert(status.error == ApiCapabilitiesReadError.invalidAttribute);
        assert(document == EditingApiCapabilitiesDocument.init);
    }

    {
        enum xml =
            "<osm version=\"0.6\"><api>" ~
            "<version minimum=\"0.6\" maximum=\"0.6\"/>" ~
            "<waynodes maximum=\"2000\"/>" ~
            "<relationmembers maximum=\"32000\"/>" ~
            "<changesets maximum_elements=\"10000\"/>";

        auto source = new MemorySource(cast(const(ubyte)[]) xml);
        EditingApiCapabilitiesDocument document;
        ApiCapabilitiesReadStatus status;

        assert(!readEditingApiCapabilities(source, document, status));
        assert(status.error == ApiCapabilitiesReadError.malformedXml ||
               status.error == ApiCapabilitiesReadError.invalidStructure);
        assert(document == EditingApiCapabilitiesDocument.init);
    }
}
