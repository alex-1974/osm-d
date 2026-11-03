module app;

import osm.osmchange;
import std.stdio : stdout;
import transport.source : MemorySink, MemorySource;

void main()
{
    enum fixture = import("osmchange/order-and-delete.osc");

    auto input = new MemorySource(cast(const(ubyte)[]) fixture);

    OsmChangeDocument document;
    OsmChangeReadStatus readStatus;
    assert(readOsmChangeDocument(input, document, readStatus));

    auto sink = new MemorySink();
    OsmChangeWriter writer;
    OsmChangeWriteStatus writeStatus;
    assert(writer.write(document, sink, writeStatus));

    stdout.rawWrite(sink.data);
}
