/**
 * Bounded XML reader for OSM Changeset read/query responses.
 *
 * The reader materializes one Changeset at a time because tags and discussion
 * comments are durable semantic values. Optional server fields retain explicit
 * presence and no HTTP behavior is implemented here.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-06
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.changeset.reader;

import dxml.parser :
    XmlEntityType = EntityType,
    XMLParsingException,
    parseXML,
    simpleXML;
import dxml.util : decodeXML;
import osm.io.changeset.document :
    ChangesetDocument,
    ChangesetDocumentInfo;
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
import osm.model.changeset :
    ChangesetBounds,
    OwnedChangeset,
    OwnedChangesetComment;
import osm.model.owned :
    OwnedBytes,
    OwnedTag,
    ownBytes;
import osm.view.location : LocationView;
import std.algorithm.comparison : equal;
import std.datetime.date : DateTimeException;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;
import std.string : indexOf;
import transport.source :
    ByteSource,
    ReadError;

/** Stable high-level failure category for Changeset XML reading. */
enum ChangesetReadError : ubyte
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

/** Diagnostic from one Changeset XML read. */
struct ChangesetReadStatus
{
    ChangesetReadError error = ChangesetReadError.none;
    ReadError transportError = ReadError.none;
    ulong byteOffset;
    int line;
    int column;

    long changesetId;
    bool hasChangesetId;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == ChangesetReadError.none;
    }
}

/**
 * Bounded-reader controls. Zero values select documented defaults.
 *
 * maximumChangesets defaults to 1,000, above the current public query maximum.
 * maximumChildrenPerChangeset and maximumCommentsPerChangeset each default to
 * 100,000. maximumCommentTextBytes defaults to 1 MiB per comment.
 */
struct ChangesetReadOptions
{
    size_t bufferSize;
    size_t maximumChangesets;
    size_t maximumChildrenPerChangeset;
    size_t maximumCommentsPerChangeset;
    size_t maximumCommentTextBytes;
    size_t maximumXmlDeclarationBytes;
}

/** Counts and root metadata from one complete successful read. */
struct ChangesetReadSummary
{
    ChangesetDocumentInfo info;
    ulong changesets;
    ulong tags;
    ulong comments;
}

/**
 * Stateless streaming Changeset response reader.
 *
 * Each delivered value is owned and may be retained independently of the
 * source. A later document failure does not roll back values already delivered;
 * use readChangesetDocument/readChangeset for transactional materialization.
 */
struct ChangesetReader
{
    bool read(Handler)(
        ByteSource source,
        ref Handler handler,
        out ChangesetReadSummary summary,
        out ChangesetReadStatus status,
        ChangesetReadOptions options = ChangesetReadOptions.init)
        @trusted
    {
        summary = ChangesetReadSummary.init;
        status = ChangesetReadStatus.init;

        if (source is null)
        {
            status.error = ChangesetReadError.transportFailure;
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
                status.error = ChangesetReadError.invalidStructure;
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
                    equal(xml.front.name.save, "osm"))
                {
                    xml.popFront();
                    while (!xml.empty && semanticXmlWhitespace(xml.front))
                        xml.popFront();

                    if (!xml.empty)
                    {
                        setPosition(status, xml.front);
                        status.error = ChangesetReadError.invalidStructure;
                        return false;
                    }

                    return true;
                }

                if (xml.front.type != XmlEntityType.elementStart ||
                    !equal(xml.front.name.save, "changeset"))
                {
                    setPosition(status, xml.front);
                    status.error = ChangesetReadError.unsupportedContent;
                    return false;
                }

                if (summary.changesets >= changesetLimit(options))
                {
                    setPosition(status, xml.front);
                    status.error = ChangesetReadError.resourceLimit;
                    return false;
                }

                OwnedChangeset value;
                ulong tags;
                ulong comments;
                if (!parseChangeset(
                        xml,
                        value,
                        tags,
                        comments,
                        status,
                        options))
                    return false;

                ++summary.changesets;
                summary.tags += tags;
                summary.comments += comments;
                deliverChangeset(handler, value);
            }

            status.error = ChangesetReadError.invalidStructure;
            return false;
        }
        catch (XmlSourceException e)
        {
            status.error = ChangesetReadError.transportFailure;
            status.transportError = e.error;
            status.byteOffset = e.offset;
            return false;
        }
        catch (XMLParsingException e)
        {
            status.error = ChangesetReadError.malformedXml;
            status.line = e.pos.line;
            status.column = e.pos.col;
            return false;
        }
    }
}

/** Transactionally materialize a Changeset read/query response. */
bool readChangesetDocument(
    ByteSource source,
    out ChangesetDocument document,
    out ChangesetReadStatus status,
    ChangesetReadOptions options = ChangesetReadOptions.init)
    @safe
{
    struct Collector
    {
        OwnedChangeset[] values;

        void changeset(OwnedChangeset value) @safe
        {
            values ~= value;
        }
    }

    document = ChangesetDocument.init;

    Collector collector;
    ChangesetReadSummary summary;
    ChangesetReader reader;

    if (!reader.read(source, collector, summary, status, options))
        return false;

    ChangesetDocument parsed;
    parsed.info = summary.info;
    parsed.changesets = collector.values;
    document = parsed;
    return true;
}

/**
 * Transactionally read exactly one Changeset.
 *
 * Empty documents and query/list responses with more than one Changeset are
 * rejected as invalidStructure rather than silently selecting an entry.
 */
bool readChangeset(
    ByteSource source,
    out OwnedChangeset changeset,
    out ChangesetReadStatus status,
    ChangesetReadOptions options = ChangesetReadOptions.init)
    @safe
{
    changeset = OwnedChangeset.init;

    ChangesetDocument document;
    if (!readChangesetDocument(source, document, status, options))
        return false;

    if (document.changesets.length != 1)
    {
        status.error = ChangesetReadError.invalidStructure;
        return false;
    }

    changeset = document.changesets[0];
    return true;
}

private:

enum size_t defaultMaximumChangesets = 1_000;
enum size_t defaultMaximumChildren = 100_000;
enum size_t defaultMaximumComments = 100_000;
enum size_t defaultMaximumCommentTextBytes = 1_048_576;

size_t changesetLimit(ChangesetReadOptions options)
    @safe pure nothrow @nogc
{
    return options.maximumChangesets == 0
        ? defaultMaximumChangesets
        : options.maximumChangesets;
}

size_t childLimit(ChangesetReadOptions options)
    @safe pure nothrow @nogc
{
    return options.maximumChildrenPerChangeset == 0
        ? defaultMaximumChildren
        : options.maximumChildrenPerChangeset;
}

size_t commentLimit(ChangesetReadOptions options)
    @safe pure nothrow @nogc
{
    return options.maximumCommentsPerChangeset == 0
        ? defaultMaximumComments
        : options.maximumCommentsPerChangeset;
}

size_t commentTextLimit(ChangesetReadOptions options)
    @safe pure nothrow @nogc
{
    return options.maximumCommentTextBytes == 0
        ? defaultMaximumCommentTextBytes
        : options.maximumCommentTextBytes;
}

OsmXmlReadOptions toXmlOptions(ChangesetReadOptions options)
    @safe pure nothrow @nogc
{
    OsmXmlReadOptions result;
    result.bufferSize = options.bufferSize;
    result.maximumXmlDeclarationBytes = options.maximumXmlDeclarationBytes;
    return result;
}

void deliverChangeset(Handler)(
    ref Handler handler,
    OwnedChangeset value) @safe
{
    static if (__traits(compiles, handler.changeset(value)))
        handler.changeset(value);
}

void setPosition(Entity)(
    ref ChangesetReadStatus status,
    Entity entity)
{
    OsmXmlReadStatus xmlStatus;
    semanticXmlPosition(xmlStatus, entity);
    status.line = xmlStatus.line;
    status.column = xmlStatus.column;
}

bool parseRootAttributes(Entity)(
    Entity entity,
    ref ChangesetDocumentInfo info,
    ref ChangesetReadStatus status)
{
    bool hasVersion;
    auto attrs = entity.attributes;

    while (!attrs.empty)
    {
        auto attr = attrs.front;
        const value = decodeXML(attr.value);

        if (equal(attr.name.save, "version"))
        {
            if (hasVersion || value != "0.6")
            {
                setPosition(status, entity);
                status.error = value == "0.6"
                    ? ChangesetReadError.invalidStructure
                    : ChangesetReadError.unsupportedVersion;
                return false;
            }

            hasVersion = true;
            info.hasVersion = true;
            info.versionText = ownBytes(cast(const(ubyte)[]) value);
        }
        else if (equal(attr.name.save, "generator"))
        {
            if (info.hasGenerator)
                return duplicateAttribute(status, entity);
            info.hasGenerator = true;
            info.generator = ownBytes(cast(const(ubyte)[]) value);
        }
        else if (equal(attr.name.save, "copyright"))
        {
            if (info.hasCopyright)
                return duplicateAttribute(status, entity);
            info.hasCopyright = true;
            info.copyrightText = ownBytes(cast(const(ubyte)[]) value);
        }
        else if (equal(attr.name.save, "attribution"))
        {
            if (info.hasAttribution)
                return duplicateAttribute(status, entity);
            info.hasAttribution = true;
            info.attribution = ownBytes(cast(const(ubyte)[]) value);
        }
        else if (equal(attr.name.save, "license"))
        {
            if (info.hasLicense)
                return duplicateAttribute(status, entity);
            info.hasLicense = true;
            info.license = ownBytes(cast(const(ubyte)[]) value);
        }
        else
        {
            setPosition(status, entity);
            status.error = ChangesetReadError.unsupportedContent;
            return false;
        }

        attrs.popFront();
    }

    if (!hasVersion)
    {
        setPosition(status, entity);
        status.error = ChangesetReadError.missingAttribute;
        return false;
    }

    return true;
}

bool parseChangeset(R)(
    ref R xml,
    out OwnedChangeset result,
    out ulong tagCount,
    out ulong commentCount,
    ref ChangesetReadStatus status,
    ChangesetReadOptions options)
{
    result = OwnedChangeset.init;
    tagCount = 0;
    commentCount = 0;

    auto entity = xml.front;

    bool hasMinLat;
    bool hasMinLon;
    bool hasMaxLat;
    bool hasMaxLon;
    long minLat;
    long minLon;
    long maxLat;
    long maxLon;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        const value = decodeXML(attr.value);

        if (equal(attr.name.save, "id"))
        {
            if (result.hasId)
                return duplicateAttribute(status, entity);

            long parsed;
            if (!parseSemanticXmlLong(value, parsed) || parsed <= 0)
                return invalidAttribute(status, entity);

            result.hasId = true;
            result.id = parsed;
            status.hasChangesetId = true;
            status.changesetId = parsed;
        }
        else if (equal(attr.name.save, "created_at"))
        {
            if (result.hasCreatedAt)
                return duplicateAttribute(status, entity);
            if (!parseTimestamp(value, result.createdAtMilliseconds, status))
            {
                setPosition(status, entity);
                return false;
            }
            result.hasCreatedAt = true;
        }
        else if (equal(attr.name.save, "closed_at"))
        {
            if (result.hasClosedAt)
                return duplicateAttribute(status, entity);
            if (!parseTimestamp(value, result.closedAtMilliseconds, status))
            {
                setPosition(status, entity);
                return false;
            }
            result.hasClosedAt = true;
        }
        else if (equal(attr.name.save, "open"))
        {
            if (result.hasOpenState)
                return duplicateAttribute(status, entity);
            if (!parseBoolean(value, result.open))
                return invalidAttribute(status, entity);
            result.hasOpenState = true;
        }
        else if (equal(attr.name.save, "uid"))
        {
            if (result.hasUserId)
                return duplicateAttribute(status, entity);
            long parsed;
            if (!parseSemanticXmlLong(value, parsed) || parsed <= 0)
                return invalidAttribute(status, entity);
            result.hasUserId = true;
            result.userId = parsed;
        }
        else if (equal(attr.name.save, "user"))
        {
            if (result.hasUsername)
                return duplicateAttribute(status, entity);
            result.hasUsername = true;
            result.username = ownBytes(cast(const(ubyte)[]) value);
        }
        else if (equal(attr.name.save, "min_lat"))
        {
            if (hasMinLat)
                return duplicateAttribute(status, entity);
            if (!parseCoordinate(value, 90, minLat, status))
            {
                setPosition(status, entity);
                return false;
            }
            hasMinLat = true;
        }
        else if (equal(attr.name.save, "min_lon"))
        {
            if (hasMinLon)
                return duplicateAttribute(status, entity);
            if (!parseCoordinate(value, 180, minLon, status))
            {
                setPosition(status, entity);
                return false;
            }
            hasMinLon = true;
        }
        else if (equal(attr.name.save, "max_lat"))
        {
            if (hasMaxLat)
                return duplicateAttribute(status, entity);
            if (!parseCoordinate(value, 90, maxLat, status))
            {
                setPosition(status, entity);
                return false;
            }
            hasMaxLat = true;
        }
        else if (equal(attr.name.save, "max_lon"))
        {
            if (hasMaxLon)
                return duplicateAttribute(status, entity);
            if (!parseCoordinate(value, 180, maxLon, status))
            {
                setPosition(status, entity);
                return false;
            }
            hasMaxLon = true;
        }
        else if (equal(attr.name.save, "comments_count"))
        {
            if (result.hasCommentsCount)
                return duplicateAttribute(status, entity);
            if (!parseUnsigned(value, result.commentsCount))
                return invalidAttribute(status, entity);
            result.hasCommentsCount = true;
        }
        else if (equal(attr.name.save, "changes_count"))
        {
            if (result.hasChangesCount)
                return duplicateAttribute(status, entity);
            if (!parseUnsigned(value, result.changesCount))
                return invalidAttribute(status, entity);
            result.hasChangesCount = true;
        }
        else if (equal(attr.name.save, "created_count"))
        {
            if (result.hasCreatedCount)
                return duplicateAttribute(status, entity);
            if (!parseUnsigned(value, result.createdCount))
                return invalidAttribute(status, entity);
            result.hasCreatedCount = true;
        }
        else if (equal(attr.name.save, "modified_count"))
        {
            if (result.hasModifiedCount)
                return duplicateAttribute(status, entity);
            if (!parseUnsigned(value, result.modifiedCount))
                return invalidAttribute(status, entity);
            result.hasModifiedCount = true;
        }
        else if (equal(attr.name.save, "deleted_count"))
        {
            if (result.hasDeletedCount)
                return duplicateAttribute(status, entity);
            if (!parseUnsigned(value, result.deletedCount))
                return invalidAttribute(status, entity);
            result.hasDeletedCount = true;
        }
        else
        {
            setPosition(status, entity);
            status.error = ChangesetReadError.unsupportedContent;
            return false;
        }

        attrs.popFront();
    }

    if (!result.hasId || !result.hasCreatedAt || !result.hasOpenState)
    {
        setPosition(status, entity);
        status.error = ChangesetReadError.missingAttribute;
        return false;
    }

    const boundsFields =
        cast(int) hasMinLat +
        cast(int) hasMinLon +
        cast(int) hasMaxLat +
        cast(int) hasMaxLon;

    if (boundsFields != 0 && boundsFields != 4)
    {
        setPosition(status, entity);
        status.error = ChangesetReadError.missingAttribute;
        return false;
    }

    if (boundsFields == 4)
    {
        if (minLat > maxLat || minLon > maxLon)
            return invalidAttribute(status, entity);

        result.hasBounds = true;
        result.bounds = ChangesetBounds(
            LocationView(minLat, minLon),
            LocationView(maxLat, maxLon));
    }

    xml.popFront();
    size_t children;
    bool seenDiscussion;

    while (!xml.empty)
    {
        if (semanticXmlWhitespace(xml.front))
        {
            xml.popFront();
            continue;
        }

        if (xml.front.type == XmlEntityType.elementEnd &&
            equal(xml.front.name.save, "changeset"))
        {
            xml.popFront();
            return true;
        }

        if (xml.front.type != XmlEntityType.elementStart)
        {
            setPosition(status, xml.front);
            status.error = ChangesetReadError.invalidStructure;
            return false;
        }

        if (children >= childLimit(options))
        {
            setPosition(status, xml.front);
            status.error = ChangesetReadError.resourceLimit;
            return false;
        }
        ++children;

        if (equal(xml.front.name.save, "tag"))
        {
            OwnedTag tag;
            if (!parseTag(xml, tag, status))
                return false;
            result.tags ~= tag;
            ++tagCount;
        }
        else if (equal(xml.front.name.save, "discussion"))
        {
            if (seenDiscussion)
            {
                setPosition(status, xml.front);
                status.error = ChangesetReadError.invalidStructure;
                return false;
            }

            if (!parseDiscussion(
                    xml,
                    result,
                    commentCount,
                    status,
                    options))
                return false;

            seenDiscussion = true;
        }
        else
        {
            setPosition(status, xml.front);
            status.error = ChangesetReadError.unsupportedContent;
            return false;
        }
    }

    status.error = ChangesetReadError.invalidStructure;
    return false;
}

bool parseTag(R)(
    ref R xml,
    out OwnedTag tag,
    ref ChangesetReadStatus status)
{
    auto entity = xml.front;
    bool hasKey;
    bool hasValue;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        const value = decodeXML(attr.value);

        if (equal(attr.name.save, "k"))
        {
            if (hasKey)
                return duplicateAttribute(status, entity);
            hasKey = true;
            tag.key = ownBytes(cast(const(ubyte)[]) value);
        }
        else if (equal(attr.name.save, "v"))
        {
            if (hasValue)
                return duplicateAttribute(status, entity);
            hasValue = true;
            tag.value = ownBytes(cast(const(ubyte)[]) value);
        }
        else
        {
            setPosition(status, entity);
            status.error = ChangesetReadError.unsupportedContent;
            return false;
        }

        attrs.popFront();
    }

    if (!hasKey || !hasValue)
    {
        setPosition(status, entity);
        status.error = ChangesetReadError.missingAttribute;
        return false;
    }

    return consumeEmptyElement(xml, "tag", status);
}

bool parseDiscussion(R)(
    ref R xml,
    ref OwnedChangeset result,
    ref ulong commentCount,
    ref ChangesetReadStatus status,
    ChangesetReadOptions options)
{
    auto entity = xml.front;
    if (!entity.attributes.empty)
    {
        setPosition(status, entity);
        status.error = ChangesetReadError.unsupportedContent;
        return false;
    }

    result.hasDiscussion = true;
    xml.popFront();

    while (!xml.empty)
    {
        if (semanticXmlWhitespace(xml.front))
        {
            xml.popFront();
            continue;
        }

        if (xml.front.type == XmlEntityType.elementEnd &&
            equal(xml.front.name.save, "discussion"))
        {
            xml.popFront();
            return true;
        }

        if (xml.front.type != XmlEntityType.elementStart ||
            !equal(xml.front.name.save, "comment"))
        {
            setPosition(status, xml.front);
            status.error = ChangesetReadError.unsupportedContent;
            return false;
        }

        if (result.comments.length >= commentLimit(options))
        {
            setPosition(status, xml.front);
            status.error = ChangesetReadError.resourceLimit;
            return false;
        }

        OwnedChangesetComment comment;
        if (!parseComment(xml, comment, status, options))
            return false;

        result.comments ~= comment;
        ++commentCount;
    }

    status.error = ChangesetReadError.invalidStructure;
    return false;
}

bool parseComment(R)(
    ref R xml,
    out OwnedChangesetComment result,
    ref ChangesetReadStatus status,
    ChangesetReadOptions options)
{
    auto entity = xml.front;

    auto attrs = entity.attributes;
    while (!attrs.empty)
    {
        auto attr = attrs.front;
        const value = decodeXML(attr.value);

        if (equal(attr.name.save, "id"))
        {
            if (result.hasId)
                return duplicateAttribute(status, entity);
            long parsed;
            if (!parseSemanticXmlLong(value, parsed) || parsed <= 0)
                return invalidAttribute(status, entity);
            result.hasId = true;
            result.id = parsed;
        }
        else if (equal(attr.name.save, "date"))
        {
            if (result.hasDate)
                return duplicateAttribute(status, entity);
            if (!parseTimestamp(value, result.dateMilliseconds, status))
            {
                setPosition(status, entity);
                return false;
            }
            result.hasDate = true;
        }
        else if (equal(attr.name.save, "uid"))
        {
            if (result.hasUserId)
                return duplicateAttribute(status, entity);
            long parsed;
            if (!parseSemanticXmlLong(value, parsed) || parsed <= 0)
                return invalidAttribute(status, entity);
            result.hasUserId = true;
            result.userId = parsed;
        }
        else if (equal(attr.name.save, "user"))
        {
            if (result.hasUsername)
                return duplicateAttribute(status, entity);
            result.hasUsername = true;
            result.username = ownBytes(cast(const(ubyte)[]) value);
        }
        else if (equal(attr.name.save, "visible"))
        {
            if (result.hasVisibility)
                return duplicateAttribute(status, entity);
            if (!parseBoolean(value, result.visible))
                return invalidAttribute(status, entity);
            result.hasVisibility = true;
        }
        else
        {
            setPosition(status, entity);
            status.error = ChangesetReadError.unsupportedContent;
            return false;
        }

        attrs.popFront();
    }

    xml.popFront();
    bool seenText;

    while (!xml.empty)
    {
        if (semanticXmlWhitespace(xml.front))
        {
            xml.popFront();
            continue;
        }

        if (xml.front.type == XmlEntityType.elementEnd &&
            equal(xml.front.name.save, "comment"))
        {
            if (!seenText)
            {
                setPosition(status, xml.front);
                status.error = ChangesetReadError.invalidStructure;
                return false;
            }
            xml.popFront();
            return true;
        }

        if (xml.front.type != XmlEntityType.elementStart ||
            !equal(xml.front.name.save, "text") ||
            seenText)
        {
            setPosition(status, xml.front);
            status.error = ChangesetReadError.unsupportedContent;
            return false;
        }

        if (!parseCommentText(xml, result, status, options))
            return false;
        seenText = true;
    }

    status.error = ChangesetReadError.invalidStructure;
    return false;
}

bool parseCommentText(R)(
    ref R xml,
    ref OwnedChangesetComment result,
    ref ChangesetReadStatus status,
    ChangesetReadOptions options)
{
    auto entity = xml.front;
    if (!entity.attributes.empty)
    {
        setPosition(status, entity);
        status.error = ChangesetReadError.unsupportedContent;
        return false;
    }

    ubyte[] bytes;
    xml.popFront();

    while (!xml.empty)
    {
        if (xml.front.type == XmlEntityType.elementEnd &&
            equal(xml.front.name.save, "text"))
        {
            result.hasText = true;
            result.text = bytes.idup;
            xml.popFront();
            return true;
        }

        if (xml.front.type != XmlEntityType.text)
        {
            setPosition(status, xml.front);
            status.error = ChangesetReadError.unsupportedContent;
            return false;
        }

        const decoded = decodeXML(xml.front.text);
        const chunk = cast(const(ubyte)[]) decoded;
        if (bytes.length > commentTextLimit(options) ||
            chunk.length > commentTextLimit(options) - bytes.length)
        {
            setPosition(status, xml.front);
            status.error = ChangesetReadError.resourceLimit;
            return false;
        }

        bytes ~= chunk;
        xml.popFront();
    }

    status.error = ChangesetReadError.invalidStructure;
    return false;
}

bool consumeEmptyElement(R)(
    ref R xml,
    string name,
    ref ChangesetReadStatus status)
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
        status.error = ChangesetReadError.invalidStructure;
        return false;
    }

    xml.popFront();
    return true;
}

bool parseUnsigned(string text, out ulong value)
    @safe pure nothrow @nogc
{
    long parsed;
    if (!parseSemanticXmlLong(text, parsed) || parsed < 0)
    {
        value = 0;
        return false;
    }

    value = cast(ulong) parsed;
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
    ref ChangesetReadStatus status)
    @safe pure nothrow @nogc
{
    nanodegrees = 0;
    if (text.length == 0)
    {
        status.error = ChangesetReadError.invalidAttribute;
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
            status.error = ChangesetReadError.invalidAttribute;
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
            status.error = ChangesetReadError.invalidAttribute;
            return false;
        }

        sawWholeDigit = true;
        const digit = cast(ulong)(c - '0');
        if (whole > (cast(ulong) wholeLimit - digit) / 10)
        {
            status.error = ChangesetReadError.invalidAttribute;
            return false;
        }

        whole = whole * 10 + digit;
        ++i;
    }

    if (!sawWholeDigit)
    {
        status.error = ChangesetReadError.invalidAttribute;
        return false;
    }

    ulong fraction;
    size_t fractionDigits;
    if (i < text.length)
    {
        ++i;
        if (i == text.length)
        {
            status.error = ChangesetReadError.invalidAttribute;
            return false;
        }

        while (i < text.length)
        {
            const c = text[i++];
            if (c < '0' || c > '9')
            {
                status.error = ChangesetReadError.invalidAttribute;
                return false;
            }

            if (fractionDigits < 9)
            {
                fraction = fraction * 10 + cast(ulong)(c - '0');
                ++fractionDigits;
            }
            else if (c != '0')
            {
                status.error = ChangesetReadError.precisionLoss;
                return false;
            }
        }
    }

    while (fractionDigits < 9)
    {
        fraction *= 10;
        ++fractionDigits;
    }

    if (whole > cast(ulong) wholeLimit ||
        (whole == cast(ulong) wholeLimit && fraction != 0))
    {
        status.error = ChangesetReadError.invalidAttribute;
        return false;
    }

    const magnitude = whole * 1_000_000_000UL + fraction;
    nanodegrees = negative
        ? -cast(long) magnitude
        : cast(long) magnitude;
    return true;
}

bool parseTimestamp(
    string text,
    out long milliseconds,
    ref ChangesetReadStatus status)
    @safe
{
    milliseconds = 0;
    if (!hasExplicitTimezone(text))
    {
        status.error = ChangesetReadError.invalidAttribute;
        return false;
    }

    try
    {
        const parsed = SysTime.fromISOExtString(text, UTC());
        const utc = parsed.toUTC();
        const epoch = SysTime.fromUnixTime(0, UTC());
        const delta = utc.stdTime - epoch.stdTime;

        if (delta % 10_000 != 0)
        {
            status.error = ChangesetReadError.precisionLoss;
            return false;
        }

        milliseconds = delta / 10_000;
        return true;
    }
    catch (DateTimeException)
    {
        status.error = ChangesetReadError.invalidAttribute;
        return false;
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

    for (size_t i = cast(size_t) t + 1; i < text.length; ++i)
    {
        if (text[i] == '+' || text[i] == '-')
            return true;
    }

    return false;
}

bool duplicateAttribute(Entity)(
    ref ChangesetReadStatus status,
    Entity entity)
{
    setPosition(status, entity);
    status.error = ChangesetReadError.invalidStructure;
    return false;
}

bool invalidAttribute(Entity)(
    ref ChangesetReadStatus status,
    Entity entity)
{
    setPosition(status, entity);
    status.error = ChangesetReadError.invalidAttribute;
    return false;
}

void mapXmlFailure(
    ref const OsmXmlReadStatus xml,
    ref ChangesetReadStatus status)
    @safe pure nothrow @nogc
{
    status.transportError = xml.transportError;
    status.byteOffset = xml.byteOffset;
    status.line = xml.line;
    status.column = xml.column;

    switch (xml.error)
    {
        case OsmXmlReadError.none:
            status.error = ChangesetReadError.none;
            break;
        case OsmXmlReadError.transportFailure:
            status.error = ChangesetReadError.transportFailure;
            break;
        case OsmXmlReadError.malformedXml:
            status.error = ChangesetReadError.malformedXml;
            break;
        case OsmXmlReadError.unsupportedEncoding:
            status.error = ChangesetReadError.unsupportedEncoding;
            break;
        case OsmXmlReadError.resourceLimit:
            status.error = ChangesetReadError.resourceLimit;
            break;
        case OsmXmlReadError.precisionLoss:
            status.error = ChangesetReadError.precisionLoss;
            break;
        default:
            status.error = ChangesetReadError.invalidStructure;
            break;
    }
}

unittest // current server-shaped open Changeset without bounds
{
    import transport.source : MemorySource;

    enum xml =
        "<osm version=\"0.6\" generator=\"OpenStreetMap server\">" ~
        "<changeset id=\"10\" created_at=\"2026-02-01T12:00:00Z\" " ~
        "open=\"true\" user=\"mapper\" uid=\"123\" " ~
        "comments_count=\"0\" changes_count=\"0\" " ~
        "created_count=\"0\" modified_count=\"0\" deleted_count=\"0\">" ~
        "<tag k=\"created_by\" v=\"osm-d\"/>" ~
        "</changeset></osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    OwnedChangeset value;
    ChangesetReadStatus status;

    assert(readChangeset(source, value, status));
    assert(status.ok);
    assert(value.hasId && value.id == 10);
    assert(value.hasOpenState && value.open);
    assert(!value.hasBounds);
    assert(value.hasCreatedCount && value.createdCount == 0);
    assert(!value.hasDiscussion);
    assert(value.tags.length == 1);
}

unittest // closed Changeset with bounds and discussion
{
    import transport.source : MemorySource;

    enum xml =
        "<osm version=\"0.6\">" ~
        "<changeset id=\"11\" created_at=\"2026-02-01T12:00:00Z\" " ~
        "closed_at=\"2026-02-01T13:00:00Z\" open=\"false\" " ~
        "min_lon=\"7.0191821\" min_lat=\"49.2785426\" " ~
        "max_lon=\"7.0197485\" max_lat=\"49.2793101\" " ~
        "comments_count=\"1\" changes_count=\"10\" " ~
        "created_count=\"2\" modified_count=\"5\" deleted_count=\"3\">" ~
        "<tag k=\"comment\" v=\"street names\"/>" ~
        "<discussion><comment id=\"1234\" date=\"2026-02-01T14:00:00Z\" " ~
        "uid=\"1841\" user=\"reviewer\">" ~
        "<text>Did you verify those street names?</text>" ~
        "</comment></discussion>" ~
        "</changeset></osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    OwnedChangeset value;
    ChangesetReadStatus status;

    assert(readChangeset(source, value, status));
    assert(!value.open);
    assert(value.hasClosedAt);
    assert(value.hasBounds);
    assert(value.bounds.minimum.latitudeNanodegrees == 49_278_542_600L);
    assert(value.bounds.maximum.longitudeNanodegrees == 7_019_748_500L);
    assert(value.hasDiscussion);
    assert(value.comments.length == 1);
    assert(value.comments[0].hasId && value.comments[0].id == 1234);
    assert(value.comments[0].hasText);
    assert(cast(string) value.comments[0].text ==
        "Did you verify those street names?");
}

unittest // partial bounds are invalid rather than guessed
{
    import transport.source : MemorySource;

    enum xml =
        "<osm version=\"0.6\"><changeset id=\"12\" " ~
        "created_at=\"2026-02-01T12:00:00Z\" open=\"true\" " ~
        "min_lat=\"1\"/></osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    OwnedChangeset value;
    ChangesetReadStatus status;

    assert(!readChangeset(source, value, status));
    assert(status.error == ChangesetReadError.missingAttribute);
    assert(value == OwnedChangeset.init);
}

unittest // query/list response shares the same semantic model
{
    import transport.source : MemorySource;

    enum xml =
        "<osm version=\"0.6\">" ~
        "<changeset id=\"1\" created_at=\"2026-01-01T00:00:00Z\" open=\"false\"/>" ~
        "<changeset id=\"2\" created_at=\"2026-01-02T00:00:00Z\" open=\"true\"/>" ~
        "</osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    ChangesetDocument document;
    ChangesetReadStatus status;

    assert(readChangesetDocument(source, document, status));
    assert(document.changesets.length == 2);
    assert(document.changesets[0].id == 1);
    assert(document.changesets[1].id == 2);
}


unittest // independently authored current API-shaped fixtures
{
    import transport.source : MemorySource;

    {
        enum fixture = import("changeset/current-open.xml");
        auto source = new MemorySource(cast(const(ubyte)[]) fixture);

        OwnedChangeset value;
        ChangesetReadStatus status;
        assert(readChangeset(source, value, status));
        assert(status.ok);
        assert(value.id == 1001);
        assert(value.open);
        assert(!value.hasBounds);
        assert(value.hasCreatedCount && value.createdCount == 0);
        assert(value.tags.length == 2);
    }

    {
        enum fixture = import("changeset/current-closed-discussion.xml");
        auto source = new MemorySource(cast(const(ubyte)[]) fixture);

        OwnedChangeset value;
        ChangesetReadStatus status;
        assert(readChangeset(source, value, status));
        assert(status.ok);
        assert(value.id == 1002);
        assert(!value.open);
        assert(value.hasBounds);
        assert(value.hasCreatedCount && value.createdCount == 2);
        assert(value.hasModifiedCount && value.modifiedCount == 5);
        assert(value.hasDeletedCount && value.deletedCount == 3);
        assert(value.hasDiscussion && value.comments.length == 1);
        assert(cast(string) value.comments[0].text == "Thanks & checked.");
    }
}
