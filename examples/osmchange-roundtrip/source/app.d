module app;

import osm.osmchange;
import osm.validate;
import std.file : read, write;
import std.stdio : stderr;
import transport.source : MemorySink, MemorySource;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: osmchange-roundtrip <input.osc> <output.osc>");
        return 2;
    }

    auto storage = read(args[1]);
    auto source = new MemorySource(cast(const(ubyte)[])storage);

    OsmChangeDocument document;
    OsmChangeReadStatus readStatus;
    if (!readOsmChangeDocument(source, document, readStatus))
    {
        stderr.writeln("osmChange read failed: ", readStatus.error);
        return 1;
    }

    CapabilityProfile capabilities;
    UploadValidationIssue issue;
    if (!validateUploadChanges(document.changes, capabilities, issue))
    {
        stderr.writeln("upload validation failed: ", issue.error);
        return 1;
    }

    auto sink = new MemorySink();
    OsmChangeWriter writer;
    OsmChangeWriteStatus writeStatus;
    if (!writer.write(document, sink, writeStatus))
    {
        stderr.writeln("osmChange write failed: ", writeStatus.error);
        return 1;
    }

    write(args[2], sink.data);
    return 0;
}
