module app;

import osm : ElementType;
import osm.model.compare :
    sameChangeSemantics,
    sameOsmSemantics;
import osm.osmchange :
    ChangeAction,
    OsmChangeDocument,
    OsmChangeReadStatus,
    OsmChangeWriteStatus,
    OsmChangeWriter,
    readOsmChangeDocument;
import osm.validate :
    CapabilityProfile,
    UploadValidationError,
    UploadValidationIssue,
    validateUploadChanges;
import osm.xml :
    OsmXmlDocument,
    OsmXmlReadStatus,
    OsmXmlWriteStatus,
    OsmXmlWriter,
    readOsmXmlDocument;
import transport.source :
    MemorySink,
    MemorySource;

void main()
{
    qualifyJosmXml();
    qualifyJosmChange();
    qualifyIdChange();
}

private void qualifyJosmXml()
{
    enum fixture = import("editors/josm-supported.osm");
    auto input = new MemorySource(cast(const(ubyte)[]) fixture);

    OsmXmlDocument document;
    OsmXmlReadStatus readStatus;
    assert(readOsmXmlDocument(input, document, readStatus));
    assert(readStatus.ok);

    assert(document.info.hasGenerator);
    assert(cast(string) document.info.generator == "JOSM");
    assert(document.info.hasUploadPolicy);
    assert(cast(string) document.info.uploadPolicy == "never");

    assert(document.data.nodes.length == 3);
    assert(document.data.ways.length == 1);
    assert(document.data.relations.length == 1);

    assert(document.data.nodes[0].id == 100);
    assert(document.data.nodes[0].metadata.hasVersion);
    assert(document.data.nodes[0].metadata.versionNumber == 4);
    assert(document.data.nodes[0].metadata.hasVisibility);
    assert(document.data.nodes[0].metadata.visible);

    const way = document.data.ways[0];
    assert(way.nodes.length == 3);
    assert(way.nodes[0].id == -3);
    assert(way.nodes[1].id == -2);
    assert(way.nodes[2].id == 100);

    const relation = document.data.relations[0];
    assert(relation.members.length == 2);
    assert(relation.members[0].type == ElementType.way);
    assert(relation.members[0].id == -1);
    assert(cast(string) relation.members[0].role == "outer");
    assert(relation.members[1].type == ElementType.node);
    assert(relation.members[1].id == -3);
    assert(cast(string) relation.members[1].role == "label");

    auto sink = new MemorySink();
    OsmXmlWriter writer;
    OsmXmlWriteStatus writeStatus;
    assert(writer.write(document, sink, writeStatus));

    auto rewritten = new MemorySource(sink.data);
    OsmXmlDocument roundTrip;
    assert(readOsmXmlDocument(rewritten, roundTrip, readStatus));
    assert(sameOsmSemantics(document.data, roundTrip.data));
    assert(roundTrip.info.hasUploadPolicy);
    assert(roundTrip.info.uploadPolicy == document.info.uploadPolicy);
}

private void qualifyJosmChange()
{
    enum fixture = import("editors/josm-supported.osc");
    auto input = new MemorySource(cast(const(ubyte)[]) fixture);

    OsmChangeDocument document;
    OsmChangeReadStatus readStatus;
    assert(readOsmChangeDocument(input, document, readStatus));
    assert(readStatus.ok);
    assert(document.info.hasGenerator);
    assert(cast(string) document.info.generator == "JOSM");

    assert(document.changes.entries.length == 6);

    UploadValidationIssue issue;
    assert(validateUploadChanges(
        document.changes,
        CapabilityProfile.unbounded(),
        issue));
    assert(issue.ok);

    CapabilityProfile restricted;
    restricted.maximumWayNodes = 1;
    assert(!validateUploadChanges(document.changes, restricted, issue));
    assert(issue.error == UploadValidationError.wayNodeLimitExceeded);

    auto sink = new MemorySink();
    OsmChangeWriter writer;
    OsmChangeWriteStatus writeStatus;
    assert(writer.write(document, sink, writeStatus));

    auto rewritten = new MemorySource(sink.data);
    OsmChangeDocument roundTrip;
    assert(readOsmChangeDocument(rewritten, roundTrip, readStatus));
    assert(sameChangeSemantics(document.changes, roundTrip.changes));
}

private void qualifyIdChange()
{
    enum fixture = import("editors/id-compatible.osc");
    auto input = new MemorySource(cast(const(ubyte)[]) fixture);

    OsmChangeDocument document;
    OsmChangeReadStatus readStatus;
    assert(readOsmChangeDocument(input, document, readStatus));
    assert(readStatus.ok);
    assert(document.info.hasGenerator);
    assert(cast(string) document.info.generator == "iD");

    assert(document.changes.entries.length == 10);

    const e = document.changes.entries;
    assert(e[0].action == ChangeAction.create &&
           e[0].type == ElementType.node);
    assert(e[1].action == ChangeAction.create &&
           e[1].type == ElementType.node);
    assert(e[2].action == ChangeAction.create &&
           e[2].type == ElementType.way);
    assert(e[3].action == ChangeAction.create &&
           e[3].type == ElementType.relation);

    assert(e[4].action == ChangeAction.modify &&
           e[4].type == ElementType.node);
    assert(e[5].action == ChangeAction.modify &&
           e[5].type == ElementType.way);
    assert(e[6].action == ChangeAction.modify &&
           e[6].type == ElementType.relation);

    assert(e[7].action == ChangeAction.deleteObject &&
           e[7].type == ElementType.relation);
    assert(e[8].action == ChangeAction.deleteObject &&
           e[8].type == ElementType.way);
    assert(e[9].action == ChangeAction.deleteObject &&
           e[9].type == ElementType.node);

    assert(e[4].metadata.hasVersion &&
           e[4].metadata.versionNumber == 4);
    assert(e[4].metadata.hasVisibility &&
           e[4].metadata.visible);

    UploadValidationIssue issue;
    assert(validateUploadChanges(
        document.changes,
        CapabilityProfile.unbounded(),
        issue));

    auto sink = new MemorySink();
    OsmChangeWriter writer;
    OsmChangeWriteStatus writeStatus;
    assert(writer.write(document, sink, writeStatus));

    auto rewritten = new MemorySource(sink.data);
    OsmChangeDocument roundTrip;
    assert(readOsmChangeDocument(rewritten, roundTrip, readStatus));
    assert(sameChangeSemantics(document.changes, roundTrip.changes));
}
