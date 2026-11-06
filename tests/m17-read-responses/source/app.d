module app;

import osm : ElementType;
import osm.xml :
    OsmXmlDocument,
    OsmXmlReadStatus,
    readOsmXmlDocument;
import transport.source : MemorySource;

@safe void main()
{
    qualifyCurrentAndVersion();
    qualifyHistory();
    qualifyWayFull();
    qualifyRelationFull();
}

private void qualifyCurrentAndVersion() @safe
{
    auto nodeCurrent = parse(import("editing-api/node-current.xml"));
    assert(nodeCurrent.data.nodes.length == 1);
    assert(nodeCurrent.data.ways.length == 0);
    assert(nodeCurrent.data.relations.length == 0);
    assert(nodeCurrent.data.nodes[0].id == 101);
    assertVersion(nodeCurrent.data.nodes[0].metadata.hasVersion,
        nodeCurrent.data.nodes[0].metadata.versionNumber, 3);
    assert(nodeCurrent.data.nodes[0].metadata.hasChangeset);
    assert(nodeCurrent.data.nodes[0].metadata.changesetId == 7001);

    auto nodeVersion = parse(import("editing-api/node-version.xml"));
    assert(nodeVersion.data.nodes.length == 1);
    assert(nodeVersion.data.nodes[0].id == 101);
    assertVersion(nodeVersion.data.nodes[0].metadata.hasVersion,
        nodeVersion.data.nodes[0].metadata.versionNumber, 2);

    auto wayCurrent = parse(import("editing-api/way-current.xml"));
    assert(wayCurrent.data.nodes.length == 0);
    assert(wayCurrent.data.ways.length == 1);
    assert(wayCurrent.data.relations.length == 0);
    assert(wayCurrent.data.ways[0].id == 201);
    assertVersion(wayCurrent.data.ways[0].metadata.hasVersion,
        wayCurrent.data.ways[0].metadata.versionNumber, 4);
    assert(wayCurrent.data.ways[0].nodes.length == 2);
    assert(wayCurrent.data.ways[0].nodes[0].id == 101);
    assert(wayCurrent.data.ways[0].nodes[1].id == 102);

    auto wayVersion = parse(import("editing-api/way-version.xml"));
    assert(wayVersion.data.ways.length == 1);
    assert(wayVersion.data.ways[0].id == 201);
    assertVersion(wayVersion.data.ways[0].metadata.hasVersion,
        wayVersion.data.ways[0].metadata.versionNumber, 2);

    auto relationCurrent = parse(import("editing-api/relation-current.xml"));
    assert(relationCurrent.data.nodes.length == 0);
    assert(relationCurrent.data.ways.length == 0);
    assert(relationCurrent.data.relations.length == 1);
    assert(relationCurrent.data.relations[0].id == 301);
    assertVersion(relationCurrent.data.relations[0].metadata.hasVersion,
        relationCurrent.data.relations[0].metadata.versionNumber, 5);
    assert(relationCurrent.data.relations[0].members.length == 2);
    assert(relationCurrent.data.relations[0].members[0].type == ElementType.way);
    assert(relationCurrent.data.relations[0].members[0].id == 201);
    assert(relationCurrent.data.relations[0].members[1].type == ElementType.node);
    assert(relationCurrent.data.relations[0].members[1].id == 101);

    auto relationVersion = parse(import("editing-api/relation-version.xml"));
    assert(relationVersion.data.relations.length == 1);
    assert(relationVersion.data.relations[0].id == 301);
    assertVersion(relationVersion.data.relations[0].metadata.hasVersion,
        relationVersion.data.relations[0].metadata.versionNumber, 3);
}

private void qualifyHistory() @safe
{
    auto nodes = parse(import("editing-api/node-history.xml"));
    assert(nodes.data.nodes.length == 3);
    assert(nodes.data.ways.length == 0);
    assert(nodes.data.relations.length == 0);
    foreach (ref const node; nodes.data.nodes)
        assert(node.id == 101);
    assertVersion(nodes.data.nodes[0].metadata.hasVersion,
        nodes.data.nodes[0].metadata.versionNumber, 1);
    assertVersion(nodes.data.nodes[1].metadata.hasVersion,
        nodes.data.nodes[1].metadata.versionNumber, 2);
    assertVersion(nodes.data.nodes[2].metadata.hasVersion,
        nodes.data.nodes[2].metadata.versionNumber, 3);

    auto ways = parse(import("editing-api/way-history.xml"));
    assert(ways.data.nodes.length == 0);
    assert(ways.data.ways.length == 3);
    assert(ways.data.relations.length == 0);
    foreach (ref const way; ways.data.ways)
        assert(way.id == 201);
    assertVersion(ways.data.ways[0].metadata.hasVersion,
        ways.data.ways[0].metadata.versionNumber, 1);
    assertVersion(ways.data.ways[1].metadata.hasVersion,
        ways.data.ways[1].metadata.versionNumber, 2);
    assertVersion(ways.data.ways[2].metadata.hasVersion,
        ways.data.ways[2].metadata.versionNumber, 3);

    auto relations = parse(import("editing-api/relation-history.xml"));
    assert(relations.data.nodes.length == 0);
    assert(relations.data.ways.length == 0);
    assert(relations.data.relations.length == 3);
    foreach (ref const relation; relations.data.relations)
        assert(relation.id == 301);
    assertVersion(relations.data.relations[0].metadata.hasVersion,
        relations.data.relations[0].metadata.versionNumber, 1);
    assertVersion(relations.data.relations[1].metadata.hasVersion,
        relations.data.relations[1].metadata.versionNumber, 2);
    assertVersion(relations.data.relations[2].metadata.hasVersion,
        relations.data.relations[2].metadata.versionNumber, 3);
}

private void qualifyWayFull() @safe
{
    auto document = parse(import("editing-api/way-full.xml"));

    assert(document.data.nodes.length == 2);
    assert(document.data.ways.length == 1);
    assert(document.data.relations.length == 0);

    const way = document.data.ways[0];
    assert(way.id == 201);
    assert(way.nodes.length == 2);
    assert(way.nodes[0].id == document.data.nodes[0].id);
    assert(way.nodes[1].id == document.data.nodes[1].id);
}

private void qualifyRelationFull() @safe
{
    auto document = parse(import("editing-api/relation-full.xml"));

    assert(document.data.nodes.length == 2);
    assert(document.data.ways.length == 1);
    assert(document.data.relations.length == 2);

    // Full relation responses contain direct relation members and nodes used by
    // direct member Ways. They do not recursively expand member Relations.
    const child = document.data.relations[0];
    const target = document.data.relations[1];

    assert(child.id == 302);
    assert(child.members.length == 1);
    assert(child.members[0].type == ElementType.node);
    assert(child.members[0].id == 999);

    assert(target.id == 301);
    assert(target.members.length == 2);
    assert(target.members[0].type == ElementType.way);
    assert(target.members[0].id == 201);
    assert(target.members[1].type == ElementType.relation);
    assert(target.members[1].id == 302);

    // Node 999 belongs only to the child Relation and is therefore intentionally
    // absent from this one-level full expansion.
    foreach (ref const node; document.data.nodes)
        assert(node.id != 999);
}

private OsmXmlDocument parse(string xml) @safe
{
    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    OsmXmlDocument document;
    OsmXmlReadStatus status;
    assert(readOsmXmlDocument(source, document, status));
    assert(status.ok);
    assert(document.info.hasVersion);
    assert(cast(string) document.info.versionText == "0.6");
    return document;
}

private void assertVersion(bool present, int actual, int expected)
    @safe pure nothrow @nogc
{
    assert(present);
    assert(actual == expected);
}
