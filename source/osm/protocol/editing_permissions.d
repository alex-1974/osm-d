/**
 * Editing API permission projection.
 *
 * The OSM /permissions endpoint exposes OAuth grants as permission names.
 * Unknown future names are preserved exactly so this model does not need a
 * release merely because the server adds another scope.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-08
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.protocol.editing_permissions;

import dxml.parser :
    XmlEntityType = EntityType,
    XMLParsingException,
    parseXML,
    simpleXML;
import dxml.util : decodeXML;
import osm.io.xml.byte_range :
    XmlCharRange,
    XmlSourceException;
import osm.io.xml.reader :
    OsmXmlReadError,
    OsmXmlReadOptions,
    OsmXmlReadStatus,
    prepareSemanticXmlEncoding,
    semanticXmlPosition,
    semanticXmlWhitespace;
import osm.model.owned :
    OwnedBytes,
    ownBytes;
import std.algorithm.comparison : equal;
import transport.source :
    ByteSource,
    ReadError;

/**
 * Permissions granted to the current Editing API connection.
 *
 * Names are retained exactly as returned by the server, including the
 * compatibility "allow_" prefix used for OAuth 2 scopes. An unauthenticated
 * connection is represented by an empty list.
 */
struct EditingApiPermissions
{
    OwnedBytes[] names;

    /// Return true when the exact permission name was reported.
    bool allows(scope const(char)[] permission) const
        @safe pure nothrow @nogc
    {
        foreach (name; names)
        {
            if (name.length != permission.length)
                continue;

            bool same = true;
            foreach (i, value; name)
            {
                if (value != cast(ubyte) permission[i])
                {
                    same = false;
                    break;
                }
            }

            if (same)
                return true;
        }

        return false;
    }

    /// Whether this connection may modify map data through the Editing API.
    @property bool canWriteMap() const @safe pure nothrow @nogc
    {
        return allows("allow_write_api");
    }
}

package(osm):

enum EditingApiPermissionsReadError : ubyte
{
    none,
    transportFailure,
    malformedXml,
    unsupportedEncoding,
    unsupportedVersion,
    invalidAttribute,
    invalidStructure,
    resourceLimit,
}

struct EditingApiPermissionsReadStatus
{
    EditingApiPermissionsReadError error =
        EditingApiPermissionsReadError.none;
    ReadError transportError = ReadError.none;
    ulong byteOffset;
    int line;
    int column;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == EditingApiPermissionsReadError.none;
    }
}

struct EditingApiPermissionsReadOptions
{
    size_t bufferSize;
    size_t maximumXmlDeclarationBytes;
    size_t maximumPermissions;
    size_t maximumPermissionNameBytes;
}

bool readEditingApiPermissions(
    ByteSource source,
    out EditingApiPermissions permissions,
    out EditingApiPermissionsReadStatus status,
    EditingApiPermissionsReadOptions options =
        EditingApiPermissionsReadOptions.init)
    @trusted
{
    permissions = EditingApiPermissions.init;
    status = EditingApiPermissionsReadStatus.init;

    if (source is null)
    {
        status.error = EditingApiPermissionsReadError.transportFailure;
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
            status.error = EditingApiPermissionsReadError.invalidStructure;
            return false;
        }

        if (!validateRoot(xml.front, status))
            return false;

        xml.popFront();
        bool seenPermissions;
        EditingApiPermissions parsed;

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

                if (!xml.empty || !seenPermissions)
                {
                    if (!xml.empty)
                        setPosition(status, xml.front);
                    status.error =
                        EditingApiPermissionsReadError.invalidStructure;
                    return false;
                }

                permissions = parsed;
                return true;
            }

            if (xml.front.type != XmlEntityType.elementStart ||
                !equal(xml.front.name.save, "permissions") ||
                seenPermissions)
            {
                setPosition(status, xml.front);
                status.error =
                    EditingApiPermissionsReadError.invalidStructure;
                return false;
            }

            if (!parsePermissions(xml, parsed, status, options))
                return false;
            seenPermissions = true;
        }

        status.error = EditingApiPermissionsReadError.invalidStructure;
        return false;
    }
    catch (XmlSourceException e)
    {
        status.error = EditingApiPermissionsReadError.transportFailure;
        status.transportError = e.error;
        status.byteOffset = e.offset;
        return false;
    }
    catch (XMLParsingException e)
    {
        status.error = EditingApiPermissionsReadError.malformedXml;
        status.line = e.pos.line;
        status.column = e.pos.col;
        return false;
    }
}

private:

enum size_t defaultMaximumPermissions = 256;
enum size_t defaultMaximumPermissionNameBytes = 255;

size_t permissionLimit(EditingApiPermissionsReadOptions options)
    @safe pure nothrow @nogc
{
    return options.maximumPermissions == 0
        ? defaultMaximumPermissions
        : options.maximumPermissions;
}

size_t permissionNameLimit(EditingApiPermissionsReadOptions options)
    @safe pure nothrow @nogc
{
    return options.maximumPermissionNameBytes == 0
        ? defaultMaximumPermissionNameBytes
        : options.maximumPermissionNameBytes;
}

OsmXmlReadOptions toXmlOptions(EditingApiPermissionsReadOptions options)
    @safe pure nothrow @nogc
{
    OsmXmlReadOptions result;
    result.bufferSize = options.bufferSize;
    result.maximumXmlDeclarationBytes = options.maximumXmlDeclarationBytes;
    return result;
}

bool validateRoot(Entity)(
    Entity entity,
    ref EditingApiPermissionsReadStatus status)
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
                status.error =
                    EditingApiPermissionsReadError.unsupportedVersion;
                return false;
            }
            hasVersion = true;
        }

        // generator/copyright/attribution/licence and future envelope
        // attributes are not permission semantics.
        attrs.popFront();
    }

    if (!hasVersion)
    {
        setPosition(status, entity);
        status.error = EditingApiPermissionsReadError.invalidStructure;
        return false;
    }

    return true;
}

bool parsePermissions(R)(
    ref R xml,
    ref EditingApiPermissions result,
    ref EditingApiPermissionsReadStatus status,
    EditingApiPermissionsReadOptions options)
{
    xml.popFront();

    while (!xml.empty)
    {
        if (semanticXmlWhitespace(xml.front))
        {
            xml.popFront();
            continue;
        }

        if (xml.front.type == XmlEntityType.elementEnd &&
            equal(xml.front.name.save, "permissions"))
        {
            xml.popFront();
            return true;
        }

        if (xml.front.type != XmlEntityType.elementStart ||
            !equal(xml.front.name.save, "permission"))
        {
            setPosition(status, xml.front);
            status.error = EditingApiPermissionsReadError.invalidStructure;
            return false;
        }

        if (result.names.length >= permissionLimit(options))
        {
            setPosition(status, xml.front);
            status.error = EditingApiPermissionsReadError.resourceLimit;
            return false;
        }

        if (!parsePermission(xml, result, status, options))
            return false;
    }

    status.error = EditingApiPermissionsReadError.invalidStructure;
    return false;
}

bool parsePermission(R)(
    ref R xml,
    ref EditingApiPermissions result,
    ref EditingApiPermissionsReadStatus status,
    EditingApiPermissionsReadOptions options)
{
    auto entity = xml.front;
    string name;
    bool hasName;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        if (equal(attr.name.save, "name"))
        {
            name = decodeXML(attr.value);
            hasName = true;
        }
        attrs.popFront();
    }

    if (!hasName || name.length == 0 ||
        name.length > permissionNameLimit(options))
    {
        setPosition(status, entity);
        status.error = name.length > permissionNameLimit(options)
            ? EditingApiPermissionsReadError.resourceLimit
            : EditingApiPermissionsReadError.invalidAttribute;
        return false;
    }

    xml.popFront();
    while (!xml.empty && semanticXmlWhitespace(xml.front))
        xml.popFront();

    if (xml.empty ||
        xml.front.type != XmlEntityType.elementEnd ||
        !equal(xml.front.name.save, "permission"))
    {
        if (!xml.empty)
            setPosition(status, xml.front);
        status.error = EditingApiPermissionsReadError.invalidStructure;
        return false;
    }

    xml.popFront();
    result.names ~= ownBytes(cast(const(ubyte)[]) name);
    return true;
}

void setPosition(Entity)(
    ref EditingApiPermissionsReadStatus status,
    Entity entity)
{
    OsmXmlReadStatus xmlStatus;
    semanticXmlPosition(xmlStatus, entity);
    status.line = xmlStatus.line;
    status.column = xmlStatus.column;
}

void mapXmlFailure(
    ref const OsmXmlReadStatus xml,
    ref EditingApiPermissionsReadStatus status)
    @safe pure nothrow @nogc
{
    status.transportError = xml.transportError;
    status.byteOffset = xml.byteOffset;
    status.line = xml.line;
    status.column = xml.column;

    switch (xml.error)
    {
        case OsmXmlReadError.none:
            status.error = EditingApiPermissionsReadError.none;
            break;
        case OsmXmlReadError.transportFailure:
            status.error =
                EditingApiPermissionsReadError.transportFailure;
            break;
        case OsmXmlReadError.malformedXml:
            status.error = EditingApiPermissionsReadError.malformedXml;
            break;
        case OsmXmlReadError.unsupportedEncoding:
            status.error =
                EditingApiPermissionsReadError.unsupportedEncoding;
            break;
        case OsmXmlReadError.unsupportedVersion:
            status.error =
                EditingApiPermissionsReadError.unsupportedVersion;
            break;
        case OsmXmlReadError.resourceLimit:
            status.error = EditingApiPermissionsReadError.resourceLimit;
            break;
        default:
            status.error =
                EditingApiPermissionsReadError.invalidStructure;
            break;
    }
}

unittest
{
    import transport.source : MemorySource;

    enum xml =
        "<osm version=\"0.6\" generator=\"OpenStreetMap server\">" ~
        "<permissions>" ~
        "<permission name=\"allow_read_prefs\"/>" ~
        "<permission name=\"allow_write_api\"/>" ~
        "</permissions></osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    EditingApiPermissions permissions;
    EditingApiPermissionsReadStatus status;
    assert(readEditingApiPermissions(source, permissions, status));
    assert(status.ok);
    assert(permissions.names.length == 2);
    assert(permissions.allows("allow_read_prefs"));
    assert(permissions.canWriteMap);
    assert(!permissions.allows("allow_write_gpx"));
}
