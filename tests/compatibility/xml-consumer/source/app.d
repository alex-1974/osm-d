module app;

import osm.xml;
import osm.compare : sameOsmSemantics;
import transport.source : MemorySink, MemorySource;

@safe void main()
{
    enum inputXml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" ~
        "<osm version=\"0.6\" generator=\"consumer\">" ~
        "<node id=\"1\" lat=\"48.2\" lon=\"16.3\">" ~
        "<tag k=\"name\" v=\"A &amp; B\"/>" ~
        "</node></osm>";

    auto input = new MemorySource(cast(const(ubyte)[]) inputXml);

    OsmXmlDocument document;
    OsmXmlReadStatus readStatus;
    assert(readOsmXmlDocument(input, document, readStatus));
    assert(readStatus.ok);
    assert(document.data.nodes.length == 1);

    auto sink = new MemorySink();
    OsmXmlWriter writer;
    OsmXmlWriteStatus writeStatus;
    assert(writer.write(document, sink, writeStatus));
    assert(writeStatus.ok);

    auto rewritten = new MemorySource(sink.data);
    OsmXmlDocument reread;
    assert(readOsmXmlDocument(rewritten, reread, readStatus));
    assert(sameOsmSemantics(document.data, reread.data));
}
