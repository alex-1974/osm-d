/**
 * Bounded XML writer for OSM Changeset create/update tag requests.
 *
 * Only the editable tag set is serialized. Server-managed Changeset fields
 * such as ID, owner, timestamps, bounds and counters are deliberately absent.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-06
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.changeset.writer;

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
import osm.model.changeset : ChangesetTagRequest;
import osm.model.owned : OwnedTag;
import std.utf : UTFException;
import transport.source :
    ByteSink,
    WriteError;

/** Stable high-level failure category for Changeset request XML writing. */
enum ChangesetWriteError : ubyte
{
    none,
    transportFailure,
    invalidText,
}

/** Diagnostic from one Changeset request write. */
struct ChangesetWriteStatus
{
    ChangesetWriteError error = ChangesetWriteError.none;
    WriteError transportError = WriteError.none;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == ChangesetWriteError.none;
    }
}

/** Writer controls. Zero/null values select documented defaults. */
struct ChangesetWriteOptions
{
    /// Buffered transport chunk size; zero selects 64 KiB.
    size_t bufferSize;

    /// Root generator attribute. Empty selects "osm-d".
    string generator;
}

/**
 * Stateless writer for the tag-only Changeset create/update request body.
 *
 * For update operations the request tags are the complete replacement set.
 * This writer performs no HTTP and does not serialize server-managed fields.
 */
struct ChangesetWriter
{
    bool write(
        ref const ChangesetTagRequest request,
        ByteSink sink,
        out ChangesetWriteStatus status,
        ChangesetWriteOptions options = ChangesetWriteOptions.init)
        @safe
    {
        return writeCore(request.tags, sink, status, options);
    }

    /** Write a request directly from an owned tag array. */
    bool writeTags(
        scope const(OwnedTag)[] tags,
        ByteSink sink,
        out ChangesetWriteStatus status,
        ChangesetWriteOptions options = ChangesetWriteOptions.init)
        @safe
    {
        return writeCore(tags, sink, status, options);
    }
}

/** Convenience function for one Changeset create/update tag request body. */
bool writeChangesetTagRequest(
    ref const ChangesetTagRequest request,
    ByteSink sink,
    out ChangesetWriteStatus status,
    ChangesetWriteOptions options = ChangesetWriteOptions.init)
    @safe
{
    ChangesetWriter writer;
    return writer.write(request, sink, status, options);
}

private:

bool writeCore(
    scope const(OwnedTag)[] tags,
    ByteSink sink,
    out ChangesetWriteStatus status,
    ChangesetWriteOptions options)
    @safe
{
    status = ChangesetWriteStatus.init;

    if (sink is null)
    {
        status.error = ChangesetWriteError.transportFailure;
        status.transportError = WriteError.destinationFailure;
        return false;
    }

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
        xml.closeStartTag();

        xml.openStartTag("changeset");
        if (tags.length == 0)
        {
            xml.closeStartTag(EmptyTag.yes);
        }
        else
        {
            xml.closeStartTag();
            foreach (ref const tag; tags)
                writeTag(xml, tag);
            xml.writeEndTag("changeset");
        }

        xml.writeEndTag("osm");
        xml.output.put('\n');
        xml.output.flush();
        return true;
    }
    catch (XmlSinkException e)
    {
        status.error = ChangesetWriteError.transportFailure;
        status.transportError = e.error;
        return false;
    }
    catch (XMLWritingException)
    {
        status.error = ChangesetWriteError.invalidText;
        return false;
    }
    catch (UTFException)
    {
        status.error = ChangesetWriteError.invalidText;
        return false;
    }
}

void writeTag(W)(ref W xml, ref const OwnedTag tag)
{
    xml.openStartTag("tag");
    xml.writeAttr("k", encodeAttr(cast(string) tag.key));
    xml.writeAttr("v", encodeAttr(cast(string) tag.value));
    xml.closeStartTag(EmptyTag.yes);
}

unittest
{
    import osm.model.owned : ownBytes;
    import transport.source : MemorySink;

    ChangesetTagRequest request;
    request.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[]) "created_by"),
        ownBytes(cast(const(ubyte)[]) "osm-d"));
    request.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[]) "comment"),
        ownBytes(cast(const(ubyte)[]) "test"));

    auto sink = new MemorySink();
    ChangesetWriteStatus status;

    assert(writeChangesetTagRequest(request, sink, status));
    assert(status.ok);

    const xml = cast(string) sink.data;
    import std.string : indexOf;
    assert(indexOf(xml, "<changeset>") >= 0);
    assert(indexOf(xml, "created_by") >= 0);
    assert(indexOf(xml, "id=") < 0);
    assert(indexOf(xml, "closed_at=") < 0);
}

unittest
{
    import transport.source : MemorySink;

    ChangesetTagRequest request;
    auto sink = new MemorySink();
    ChangesetWriteStatus status;

    assert(writeChangesetTagRequest(request, sink, status));
    assert(status.ok);
    import std.string : indexOf;
    assert(indexOf(cast(string) sink.data, "<changeset/>") >= 0);
}
