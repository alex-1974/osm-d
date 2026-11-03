/**
 * Streaming semantic writer for OSM osmChange 0.6 documents.
 *
 * Change entry order is preserved exactly. Consecutive entries with the same
 * operation are grouped into one XML action section; a new section is emitted
 * whenever the action or delete if-unused policy changes.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.osmchange.writer;

import dxml.util : encodeAttr;
import dxml.writer :
    EmptyTag,
    Newline,
    XMLWritingException,
    writeXMLDecl,
    xmlWriter;
import osm.io.osmchange.document :
    OsmChangeDocument,
    OsmChangeDocumentInfo;
import osm.io.xml.byte_range :
    XmlSinkException,
    XmlSinkOutput;
import osm.io.xml.writer :
    OsmXmlWriteStatus,
    formatSemanticXmlNanodegrees,
    semanticXmlValidLocation,
    writeSemanticXmlMetadata;
import osm.model.change :
    ChangeAction,
    ChangeObjectState,
    OwnedChangeEntry,
    OwnedChangeSequence;
import osm.model.owned :
    OwnedMetadata,
    OwnedRelationMember,
    OwnedTag;
import osm.view.element :
    ElementType,
    OsmId;
import std.conv : to;
import std.utf : UTFException;
import transport.source :
    ByteSink,
    WriteError;

/** Stable high-level failure category for osmChange writing. */
enum OsmChangeWriteError : ubyte
{
    none,
    transportFailure,
    unsupportedVersion,
    invalidEntry,
    incompleteObject,
    unrepresentableContent,
    invalidText,
}

/** Diagnostic from one osmChange write. */
struct OsmChangeWriteStatus
{
    OsmChangeWriteError error = OsmChangeWriteError.none;
    WriteError transportError = WriteError.none;

    ChangeAction action;
    bool hasAction;

    ElementType elementType;
    OsmId elementId;
    bool hasElementIdentity;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == OsmChangeWriteError.none;
    }
}

/** Writer controls. Zero/null values select documented defaults. */
struct OsmChangeWriteOptions
{
    /// Buffered transport chunk size; zero selects 64 KiB.
    size_t bufferSize;

    /// Root generator attribute. Empty selects "osm-d".
    string generator;
}

/**
 * Stateless streaming osmChange writer.
 *
 * Semantic preflight runs before the first byte is emitted. Transport or XML
 * output failure after writing begins may still leave a valid prefix in the
 * destination; file replacement remains the caller/transport policy.
 */
struct OsmChangeWriter
{
    bool write(
        ref const OsmChangeDocument document,
        ByteSink sink,
        out OsmChangeWriteStatus status,
        OsmChangeWriteOptions options = OsmChangeWriteOptions.init)
        @safe
    {
        return writeCore(
            document.info,
            document.changes,
            sink,
            status,
            options);
    }

    /** Write a change sequence using a standard osmChange envelope. */
    bool writeChanges(
        ref const OwnedChangeSequence changes,
        ByteSink sink,
        out OsmChangeWriteStatus status,
        OsmChangeWriteOptions options = OsmChangeWriteOptions.init)
        @safe
    {
        const OsmChangeDocumentInfo info;
        return writeCore(info, changes, sink, status, options);
    }
}

private:

bool writeCore(
    ref const OsmChangeDocumentInfo info,
    ref const OwnedChangeSequence changes,
    ByteSink sink,
    out OsmChangeWriteStatus status,
    OsmChangeWriteOptions options)
    @safe
{
    status = OsmChangeWriteStatus.init;

    if (sink is null)
    {
        status.error = OsmChangeWriteError.transportFailure;
        status.transportError = WriteError.destinationFailure;
        return false;
    }

    if (info.hasVersion &&
        cast(string) info.versionText != "0.6")
    {
        status.error = OsmChangeWriteError.unsupportedVersion;
        return false;
    }

    if (!preflight(changes, status))
        return false;

    try
    {
        auto output = new XmlSinkOutput(sink, options.bufferSize);
        writeXMLDecl!string(output);
        output.put('\n');

        auto xml = xmlWriter(output, "  ");

        xml.openStartTag("osmChange", Newline.no);
        xml.writeAttr("version", "0.6");

        const generator = options.generator.length
            ? options.generator
            : "osm-d";
        xml.writeAttr("generator", encodeAttr(generator));
        xml.closeStartTag();

        bool groupOpen;
        ChangeAction currentAction;
        bool currentDeleteIfUnused;

        foreach (ref const entry; changes.entries)
        {
            if (!groupOpen ||
                entry.action != currentAction ||
                (entry.action == ChangeAction.deleteObject &&
                 entry.deleteIfUnused != currentDeleteIfUnused))
            {
                if (groupOpen)
                    xml.writeEndTag(actionName(currentAction));

                currentAction = entry.action;
                currentDeleteIfUnused = entry.deleteIfUnused;

                xml.openStartTag(actionName(currentAction));
                if (currentAction == ChangeAction.deleteObject &&
                    currentDeleteIfUnused)
                {
                    xml.writeAttr("if-unused", "true");
                }
                xml.closeStartTag();
                groupOpen = true;
            }

            writeEntry(xml, entry, status);
        }

        if (groupOpen)
            xml.writeEndTag(actionName(currentAction));

        xml.writeEndTag("osmChange");
        xml.output.put('\n');
        xml.output.flush();
        return true;
    }
    catch (XmlSinkException e)
    {
        status.error = OsmChangeWriteError.transportFailure;
        status.transportError = e.error;
        return false;
    }
    catch (XMLWritingException)
    {
        status.error = OsmChangeWriteError.invalidText;
        return false;
    }
    catch (UTFException)
    {
        status.error = OsmChangeWriteError.invalidText;
        return false;
    }
}

bool preflight(
    ref const OwnedChangeSequence changes,
    ref OsmChangeWriteStatus status)
    @safe pure nothrow @nogc
{
    foreach (ref const entry; changes.entries)
    {
        status.action = entry.action;
        status.hasAction = true;
        status.elementType = entry.type;
        status.elementId = entry.id;
        status.hasElementIdentity = true;

        if (!entry.shapeValid)
        {
            status.error = OsmChangeWriteError.invalidEntry;
            return false;
        }

        if ((entry.action == ChangeAction.create ||
             entry.action == ChangeAction.modify) &&
            entry.objectState != ChangeObjectState.complete)
        {
            status.error = OsmChangeWriteError.incompleteObject;
            return false;
        }

        if (entry.objectState == ChangeObjectState.identityOnly)
            continue;

        final switch (entry.type)
        {
            case ElementType.node:
                if (!semanticXmlValidLocation(
                        entry.location.latitudeNanodegrees,
                        entry.location.longitudeNanodegrees))
                {
                    status.error = OsmChangeWriteError.invalidEntry;
                    return false;
                }
                break;

            case ElementType.way:
                foreach (ref const nodeRef; entry.wayNodes)
                {
                    if (nodeRef.hasLocation)
                    {
                        status.error =
                            OsmChangeWriteError.unrepresentableContent;
                        return false;
                    }
                }
                break;

            case ElementType.relation:
                break;
        }
    }

    status = OsmChangeWriteStatus.init;
    return true;
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

void writeEntry(W)(
    ref W xml,
    ref const OwnedChangeEntry entry,
    ref OsmChangeWriteStatus status)
{
    status.action = entry.action;
    status.hasAction = true;
    status.elementType = entry.type;
    status.elementId = entry.id;
    status.hasElementIdentity = true;

    if (entry.objectState == ChangeObjectState.identityOnly)
    {
        writeIdentityOnlyDelete(xml, entry);
        return;
    }

    final switch (entry.type)
    {
        case ElementType.node:
            writeCompleteNode(xml, entry);
            break;
        case ElementType.way:
            writeCompleteWay(xml, entry);
            break;
        case ElementType.relation:
            writeCompleteRelation(xml, entry);
            break;
    }
}

void writeIdentityOnlyDelete(W)(
    ref W xml,
    ref const OwnedChangeEntry entry)
{
    xml.openStartTag(elementName(entry.type));
    xml.writeAttr("id", entry.id.to!string);
    writeSemanticXmlMetadata(xml, entry.metadata);
    xml.closeStartTag(EmptyTag.yes);
}

void writeCompleteNode(W)(
    ref W xml,
    ref const OwnedChangeEntry entry)
{
    xml.openStartTag("node");
    xml.writeAttr("id", entry.id.to!string);
    xml.writeAttr(
        "lat",
        formatSemanticXmlNanodegrees(
            entry.location.latitudeNanodegrees));
    xml.writeAttr(
        "lon",
        formatSemanticXmlNanodegrees(
            entry.location.longitudeNanodegrees));
    writeSemanticXmlMetadata(xml, entry.metadata);

    if (entry.tags.length == 0)
    {
        xml.closeStartTag(EmptyTag.yes);
        return;
    }

    xml.closeStartTag();
    foreach (ref const tag; entry.tags)
        writeTag(xml, tag);
    xml.writeEndTag("node");
}

void writeCompleteWay(W)(
    ref W xml,
    ref const OwnedChangeEntry entry)
{
    xml.openStartTag("way");
    xml.writeAttr("id", entry.id.to!string);
    writeSemanticXmlMetadata(xml, entry.metadata);

    if (entry.wayNodes.length == 0 && entry.tags.length == 0)
    {
        xml.closeStartTag(EmptyTag.yes);
        return;
    }

    xml.closeStartTag();

    foreach (ref const nodeRef; entry.wayNodes)
    {
        xml.openStartTag("nd");
        xml.writeAttr("ref", nodeRef.id.to!string);
        xml.closeStartTag(EmptyTag.yes);
    }

    foreach (ref const tag; entry.tags)
        writeTag(xml, tag);

    xml.writeEndTag("way");
}

void writeCompleteRelation(W)(
    ref W xml,
    ref const OwnedChangeEntry entry)
{
    xml.openStartTag("relation");
    xml.writeAttr("id", entry.id.to!string);
    writeSemanticXmlMetadata(xml, entry.metadata);

    if (entry.relationMembers.length == 0 && entry.tags.length == 0)
    {
        xml.closeStartTag(EmptyTag.yes);
        return;
    }

    xml.closeStartTag();

    foreach (ref const member; entry.relationMembers)
        writeMember(xml, member);

    foreach (ref const tag; entry.tags)
        writeTag(xml, tag);

    xml.writeEndTag("relation");
}

void writeTag(W)(
    ref W xml,
    ref const OwnedTag tag)
{
    xml.openStartTag("tag");
    xml.writeAttr("k", encodeAttr(cast(string) tag.key));
    xml.writeAttr("v", encodeAttr(cast(string) tag.value));
    xml.closeStartTag(EmptyTag.yes);
}

void writeMember(W)(
    ref W xml,
    ref const OwnedRelationMember member)
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

unittest
{
    import osm.io.osmchange.reader :
        OsmChangeReadStatus,
        readOsmChangeDocument;
    import osm.model.compare : sameChangeSemantics;
    import osm.model.owned :
        OwnedNode,
        OwnedWay,
        OwnedWayNode;
    import osm.view.location : LocationView;
    import transport.source :
        MemorySink,
        MemorySource;

    OwnedChangeSequence changes;

    OwnedNode node;
    node.id = -1;
    node.location = LocationView(48_200_000_000L, 16_300_000_000L);
    changes.entries ~= OwnedChangeEntry.fromNode(ChangeAction.create, node);

    OwnedWay way;
    way.id = 10;
    way.metadata.hasVersion = true;
    way.metadata.versionNumber = 3;
    way.nodes ~= OwnedWayNode(-1);
    changes.entries ~= OwnedChangeEntry.fromWay(ChangeAction.modify, way);

    OwnedMetadata deleteMetadata;
    deleteMetadata.hasVersion = true;
    deleteMetadata.versionNumber = 2;
    changes.entries ~= OwnedChangeEntry.deletion(
        ElementType.relation,
        20,
        deleteMetadata,
        true);

    // Repeat create after delete to prove source order is not canonicalized.
    OwnedNode second;
    second.id = -2;
    second.location = LocationView(48_210_000_000L, 16_310_000_000L);
    changes.entries ~= OwnedChangeEntry.fromNode(ChangeAction.create, second);

    auto sink = new MemorySink();
    OsmChangeWriter writer;
    OsmChangeWriteStatus writeStatus;
    assert(writer.writeChanges(changes, sink, writeStatus));
    assert(writeStatus.ok);

    auto source = new MemorySource(sink.data);
    OsmChangeDocument roundTrip;
    OsmChangeReadStatus readStatus;
    assert(readOsmChangeDocument(source, roundTrip, readStatus));
    assert(readStatus.ok);
    assert(sameChangeSemantics(changes, roundTrip.changes));
}

unittest
{
    import transport.source : MemorySink;

    OwnedChangeSequence changes;
    OwnedChangeEntry invalid;
    invalid.action = ChangeAction.modify;
    invalid.type = ElementType.node;
    invalid.id = 1;
    invalid.objectState = ChangeObjectState.identityOnly;
    changes.entries ~= invalid;

    auto sink = new MemorySink();
    OsmChangeWriter writer;
    OsmChangeWriteStatus status;
    assert(!writer.writeChanges(changes, sink, status));
    assert(status.error == OsmChangeWriteError.incompleteObject ||
           status.error == OsmChangeWriteError.invalidEntry);
    assert(sink.data.length == 0);
}
