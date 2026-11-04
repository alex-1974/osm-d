module app;

import osm.model.compare : sameOsmSemantics;
import osm.xml;
import std.file : read, write;
import std.stdio : stderr;
import transport.source : MemorySink, MemorySource;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: xml-roundtrip <input.osm> <output.osm>");
        return 2;
    }

    auto storage = read(args[1]);
    auto source = new MemorySource(cast(const(ubyte)[])storage);

    OsmXmlDocument document;
    OsmXmlReadStatus readStatus;
    if (!readOsmXmlDocument(source, document, readStatus))
    {
        stderr.writeln("XML read failed: ", readStatus.error);
        return 1;
    }

    auto sink = new MemorySink();
    OsmXmlWriter writer;
    OsmXmlWriteStatus writeStatus;
    if (!writer.write(document, sink, writeStatus))
    {
        stderr.writeln("XML write failed: ", writeStatus.error);
        return 1;
    }

    auto verifySource = new MemorySource(sink.data);
    OsmXmlDocument reread;
    if (!readOsmXmlDocument(verifySource, reread, readStatus) ||
        !sameOsmSemantics(document.data, reread.data))
    {
        stderr.writeln("semantic XML round-trip verification failed");
        return 1;
    }

    write(args[2], sink.data);
    return 0;
}
