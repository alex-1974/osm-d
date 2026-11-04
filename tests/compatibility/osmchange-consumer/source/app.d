module app;

import osm.model.compare : sameChangeSemantics;
import osm.osmchange;
import transport.source : MemorySink, MemorySource;

@safe void main()
{
    enum inputXml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" ~
        "<osmChange version=\"0.6\" generator=\"consumer\">" ~
        "<create><node id=\"-1\" lat=\"48.2\" lon=\"16.3\"/></create>" ~
        "<delete if-unused=\"true\"><way id=\"7\" version=\"2\"/></delete>" ~
        "</osmChange>";

    auto input = new MemorySource(cast(const(ubyte)[]) inputXml);

    OsmChangeDocument document;
    OsmChangeReadStatus readStatus;
    assert(readOsmChangeDocument(input, document, readStatus));
    assert(readStatus.ok);
    assert(document.changes.entries.length == 2);

    auto sink = new MemorySink();
    OsmChangeWriter writer;
    OsmChangeWriteStatus writeStatus;
    assert(writer.write(document, sink, writeStatus));
    assert(writeStatus.ok);

    auto rewritten = new MemorySource(sink.data);
    OsmChangeDocument reread;
    assert(readOsmChangeDocument(rewritten, reread, readStatus));
    assert(sameChangeSemantics(document.changes, reread.changes));
}
