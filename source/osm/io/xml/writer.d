/**
 * Streaming semantic writer for ordinary OSM XML 0.6 documents.
 *
 * dxml performs XML syntax validation/escaping while transport-d owns the byte
 * destination. The writer emits complete Node/Way/Relation objects and fails
 * when the shared semantic model contains information ordinary OSM XML cannot
 * express, such as LocationsOnWays coordinates.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.xml.writer;

import core.time : msecs;
import dxml.util : encodeAttr;
import dxml.writer :
    EmptyTag,
    Newline,
    XMLWritingException,
    writeXMLDecl,
    xmlWriter;
import osm.io.xml.byte_range :
    XmlSinkException,
    XmlSinkOutput;
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
    OwnedWay;
import osm.view.element : ElementType, OsmId;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;
import std.utf : UTFException;
import transport.source :
    ByteSink,
    WriteError;

/** Stable high-level failure category for OSM XML writing. */
enum OsmXmlWriteError : ubyte
{
    none,
    transportFailure,
    unsupportedVersion,
    unrepresentableContent,
    invalidElement,
    invalidText,
}

/** Diagnostic from one streaming OSM XML write. */
struct OsmXmlWriteStatus
{
    OsmXmlWriteError error = OsmXmlWriteError.none;
    WriteError transportError = WriteError.none;
    ElementType elementType;
    OsmId elementId;
    bool hasElementIdentity;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == OsmXmlWriteError.none;
    }
}

/** Writer controls. Zero/null values select documented defaults. */
struct OsmXmlWriteOptions
{
    /// Buffered transport chunk size; zero selects 64 KiB.
    size_t bufferSize;

    /**
     * Generator root attribute.
     *
     * null/empty selects "osm-d". The source document's generator is observed
     * by the reader but is not reused automatically, because the serializer is
     * the producer of the new XML bytes.
     */
    string generator;
}

/**
 * Stateless streaming OSM XML writer.
 *
 * .init is ready to use. Because the destination is a streaming ByteSink,
 * transport or validation failure after output has begun may leave a valid
 * prefix in the sink. Applications replacing files should use the safe
 * temporary-output/rename policy described by the workspace integrity
 * contract.
 */
struct OsmXmlWriter
{
    bool write(
        ref const OsmXmlDocument document,
        ByteSink sink,
        out OsmXmlWriteStatus status,
        OsmXmlWriteOptions options = OsmXmlWriteOptions.init)
        @safe
    {
        return writeCore(document.info, document.data, sink, status, options);
    }

    /** Write a dataset using a standard OSM XML envelope. */
    bool writeDataset(
        ref const OwnedDataset dataset,
        ByteSink sink,
        out OsmXmlWriteStatus status,
        OsmXmlWriteOptions options = OsmXmlWriteOptions.init)
        @safe
    {
        const OsmXmlDocumentInfo info;
        return writeCore(info, dataset, sink, status, options);
    }
}

private:

bool writeCore(
    ref const OsmXmlDocumentInfo info,
    ref const OwnedDataset data,
    ByteSink sink,
    out OsmXmlWriteStatus status,
    OsmXmlWriteOptions options)
    @safe
{
    status = OsmXmlWriteStatus.init;

    if (sink is null)
    {
        status.error = OsmXmlWriteError.transportFailure;
        status.transportError = WriteError.destinationFailure;
        return false;
    }

    if (info.hasVersion &&
        cast(string) info.versionText != "0.6")
    {
        status.error = OsmXmlWriteError.unsupportedVersion;
        return false;
    }

    if (!preflight(data, status))
        return false;

    try
    {
        auto output = new XmlSinkOutput(sink, options.bufferSize);
        writeXMLDecl!string(output);
        output.put('\n');

        auto xml = xmlWriter(output, "  ");

        xml.openStartTag("osm", Newline.no);
        xml.writeAttr("version", "0.6");

        const generator = options.generator.length
            ? options.generator
            : "osm-d";
        xml.writeAttr("generator", encodeAttr(generator));

        if (info.hasUploadPolicy)
            xml.writeAttr(
                "upload",
                encodeAttr(cast(string) info.uploadPolicy));

        if (info.hasCopyright)
            xml.writeAttr(
                "copyright",
                encodeAttr(cast(string) info.copyrightText));
        if (info.hasAttribution)
            xml.writeAttr(
                "attribution",
                encodeAttr(cast(string) info.attribution));
        if (info.hasLicense)
            xml.writeAttr(
                "license",
                encodeAttr(cast(string) info.license));

        xml.closeStartTag();

        foreach (ref const bounds; info.bounds)
            writeBounds(xml, bounds);

        foreach (ref const node; data.nodes)
            writeNode(xml, node, status);

        foreach (ref const way; data.ways)
            writeWay(xml, way, status);

        foreach (ref const relation; data.relations)
            writeRelation(xml, relation, status);

        xml.writeEndTag("osm");
        xml.output.put('\n');
        xml.output.flush();
        return true;
    }
    catch (XmlSinkException e)
    {
        status.error = OsmXmlWriteError.transportFailure;
        status.transportError = e.error;
        return false;
    }
    catch (XMLWritingException)
    {
        status.error = OsmXmlWriteError.invalidText;
        return false;
    }
    catch (UTFException)
    {
        status.error = OsmXmlWriteError.invalidText;
        return false;
    }
}
void setIdentity(
    ref OsmXmlWriteStatus status,
    ElementType type,
    OsmId id) @safe pure nothrow @nogc
{
    status.elementType = type;
    status.elementId = id;
    status.hasElementIdentity = true;
}

bool validLocation(long lat, long lon)
    @safe pure nothrow @nogc
{
    return lat >= -90_000_000_000L &&
           lat <=  90_000_000_000L &&
           lon >= -180_000_000_000L &&
           lon <=  180_000_000_000L;
}

bool preflight(
    ref const OwnedDataset dataset,
    ref OsmXmlWriteStatus status)
    @safe pure nothrow @nogc
{
    foreach (ref const node; dataset.nodes)
    {
        if (!validLocation(
                node.location.latitudeNanodegrees,
                node.location.longitudeNanodegrees))
        {
            setIdentity(status, ElementType.node, node.id);
            status.error = OsmXmlWriteError.invalidElement;
            return false;
        }
    }

    foreach (ref const way; dataset.ways)
    {
        foreach (ref const nodeRef; way.nodes)
        {
            if (nodeRef.hasLocation)
            {
                setIdentity(status, ElementType.way, way.id);
                status.error = OsmXmlWriteError.unrepresentableContent;
                return false;
            }
        }
    }

    return true;
}

void writeBounds(W)(ref W xml, ref const OsmXmlBounds bounds)
{
    xml.openStartTag("bounds");
    xml.writeAttr(
        "minlat",
        formatNanodegrees(bounds.minimum.latitudeNanodegrees));
    xml.writeAttr(
        "minlon",
        formatNanodegrees(bounds.minimum.longitudeNanodegrees));
    xml.writeAttr(
        "maxlat",
        formatNanodegrees(bounds.maximum.latitudeNanodegrees));
    xml.writeAttr(
        "maxlon",
        formatNanodegrees(bounds.maximum.longitudeNanodegrees));

    if (bounds.hasOrigin)
        xml.writeAttr("origin", encodeAttr(cast(string) bounds.origin));

    xml.closeStartTag(EmptyTag.yes);
}

void writeNode(W)(
    ref W xml,
    ref const OwnedNode node,
    ref OsmXmlWriteStatus status)
{
    setIdentity(status, ElementType.node, node.id);

    xml.openStartTag("node");
    xml.writeAttr("id", node.id.to!string);
    xml.writeAttr(
        "lat",
        formatNanodegrees(node.location.latitudeNanodegrees));
    xml.writeAttr(
        "lon",
        formatNanodegrees(node.location.longitudeNanodegrees));
    writeMetadata(xml, node.metadata);

    if (node.tags.length == 0)
    {
        xml.closeStartTag(EmptyTag.yes);
        return;
    }

    xml.closeStartTag();
    foreach (ref const tag; node.tags)
        writeTag(xml, tag);
    xml.writeEndTag("node");
}

void writeWay(W)(
    ref W xml,
    ref const OwnedWay way,
    ref OsmXmlWriteStatus status)
{
    setIdentity(status, ElementType.way, way.id);

    xml.openStartTag("way");
    xml.writeAttr("id", way.id.to!string);
    writeMetadata(xml, way.metadata);

    if (way.nodes.length == 0 && way.tags.length == 0)
    {
        xml.closeStartTag(EmptyTag.yes);
        return;
    }

    xml.closeStartTag();

    foreach (ref const nodeRef; way.nodes)
    {
        xml.openStartTag("nd");
        xml.writeAttr("ref", nodeRef.id.to!string);
        xml.closeStartTag(EmptyTag.yes);
    }

    foreach (ref const tag; way.tags)
        writeTag(xml, tag);

    xml.writeEndTag("way");
}

void writeRelation(W)(
    ref W xml,
    ref const OwnedRelation relation,
    ref OsmXmlWriteStatus status)
{
    setIdentity(status, ElementType.relation, relation.id);

    xml.openStartTag("relation");
    xml.writeAttr("id", relation.id.to!string);
    writeMetadata(xml, relation.metadata);

    if (relation.members.length == 0 && relation.tags.length == 0)
    {
        xml.closeStartTag(EmptyTag.yes);
        return;
    }

    xml.closeStartTag();

    foreach (ref const member; relation.members)
        writeMember(xml, member);

    foreach (ref const tag; relation.tags)
        writeTag(xml, tag);

    xml.writeEndTag("relation");
}

void writeTag(W)(ref W xml, ref const OwnedTag tag)
{
    xml.openStartTag("tag");
    xml.writeAttr("k", encodeAttr(cast(string) tag.key));
    xml.writeAttr("v", encodeAttr(cast(string) tag.value));
    xml.closeStartTag(EmptyTag.yes);
}

void writeMember(W)(ref W xml, ref const OwnedRelationMember member)
{
    xml.openStartTag("member");

    final switch (member.type)
    {
        case ElementType.node:
            xml.writeAttr("type", "node");
            break;
        case ElementType.way:
            xml.writeAttr("type", "way");
            break;
        case ElementType.relation:
            xml.writeAttr("type", "relation");
            break;
    }

    xml.writeAttr("ref", member.id.to!string);
    xml.writeAttr("role", encodeAttr(cast(string) member.role));
    xml.closeStartTag(EmptyTag.yes);
}

void writeMetadata(W)(ref W xml, ref const OwnedMetadata metadata)
{
    if (metadata.hasVersion)
        xml.writeAttr("version", metadata.versionNumber.to!string);

    if (metadata.hasTimestamp)
        xml.writeAttr(
            "timestamp",
            formatTimestampMilliseconds(metadata.timestampMilliseconds));

    if (metadata.hasChangeset)
        xml.writeAttr("changeset", metadata.changesetId.to!string);

    if (metadata.hasUserId)
        xml.writeAttr("uid", metadata.userId.to!string);

    if (metadata.hasUsername)
        xml.writeAttr(
            "user",
            encodeAttr(cast(string) metadata.username));

    if (metadata.hasVisibility)
        xml.writeAttr(
            "visible",
            metadata.visible ? "true" : "false");
}

string formatNanodegrees(long value) @safe
{
    bool negative = value < 0;
    ulong magnitude = negative
        ? cast(ulong)(-(value + 1)) + 1
        : cast(ulong)value;

    const whole = magnitude / 1_000_000_000UL;
    auto fraction = magnitude % 1_000_000_000UL;

    string result = negative ? "-" : "";
    result ~= whole.to!string;

    if (fraction == 0)
        return result;

    char[9] digits;
    for (int i = 8; i >= 0; --i)
    {
        digits[i] = cast(char)('0' + fraction % 10);
        fraction /= 10;
    }

    size_t used = digits.length;
    while (used > 0 && digits[used - 1] == '0')
        --used;

    result ~= '.';
    result ~= digits[0 .. used];
    return result;
}

string formatTimestampMilliseconds(long milliseconds) @safe
{
    long seconds = milliseconds / 1000;
    long remainder = milliseconds % 1000;

    if (remainder < 0)
    {
        --seconds;
        remainder += 1000;
    }

    auto time = SysTime.fromUnixTime(seconds, UTC());
    if (remainder != 0)
        time.fracSecs = msecs(remainder);

    return time.toISOExtString();
}

unittest
{
    assert(formatNanodegrees(48_208_174_300L) == "48.2081743");
    assert(formatNanodegrees(-16_373_818_900L) == "-16.3738189");
    assert(formatNanodegrees(0) == "0");

    assert(formatTimestampMilliseconds(0) == "1970-01-01T00:00:00Z");
    assert(formatTimestampMilliseconds(123) ==
        "1970-01-01T00:00:00.123Z");
}


unittest // semantic XML round trip
{
    import osm.io.xml.reader :
        OsmXmlReadStatus,
        readOsmXmlDocument;
    import osm.model.compare : sameOsmSemantics;
    import osm.model.owned : OwnedWay, OwnedWayNode;
    import osm.view.location : LocationView;
    import transport.source : MemorySink, MemorySource;

    enum fixture = import("xml/osm-api-style.osm");
    auto input = new MemorySource(cast(const(ubyte)[]) fixture);

    OsmXmlDocument original;
    OsmXmlReadStatus readStatus;
    assert(readOsmXmlDocument(input, original, readStatus));

    auto sink = new MemorySink();
    OsmXmlWriter writer;
    OsmXmlWriteStatus writeStatus;
    assert(writer.write(original, sink, writeStatus));
    assert(writeStatus.ok);
    assert(sink.data.length > 0);

    auto rewritten = new MemorySource(sink.data);
    OsmXmlDocument roundTrip;
    assert(readOsmXmlDocument(rewritten, roundTrip, readStatus));

    assert(sameOsmSemantics(original.data, roundTrip.data));
    assert(roundTrip.info.hasUploadPolicy);
    assert(roundTrip.info.uploadPolicy == original.info.uploadPolicy);
    // The new serializer truthfully identifies itself as the generator.
    assert(roundTrip.info.hasGenerator);
    assert(cast(string) roundTrip.info.generator == "osm-d");
}

unittest // refuse semantics ordinary OSM XML cannot represent
{
    import osm.model.owned : OwnedWay, OwnedWayNode;
    import osm.view.location : LocationView;
    import transport.source : MemorySink;

    OwnedDataset dataset;
    OwnedWay way;
    way.id = 10;

    OwnedWayNode nodeRef;
    nodeRef.id = 1;
    nodeRef.hasLocation = true;
    nodeRef.location = LocationView(1, 2);
    way.nodes ~= nodeRef;
    dataset.ways ~= way;

    auto sink = new MemorySink();
    OsmXmlWriter writer;
    OsmXmlWriteStatus status;
    assert(!writer.writeDataset(dataset, sink, status));
    assert(status.error == OsmXmlWriteError.unrepresentableContent);
    assert(status.hasElementIdentity);
    assert(status.elementType == ElementType.way);
    assert(status.elementId == 10);
    assert(sink.data.length == 0);
}
