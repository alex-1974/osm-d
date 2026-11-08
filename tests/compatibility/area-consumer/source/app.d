module app;

import osm :
    ElementType,
    LocationView,
    OwnedDataset,
    OwnedNode,
    OwnedNodeRef,
    OwnedRelation,
    OwnedRelationMember,
    OwnedTag,
    OwnedWay;
import osm.area :
    AreaAssemblyState,
    AreaRingRole,
    assembleClosedWayArea,
    assembleMultipolygon;
import osm.topology : OwnedDatasetIndex;
import osm.validate : DatasetValidationIssue;

private immutable(ubyte)[] bytes(string value)
{
    return cast(immutable(ubyte)[])value;
}

void main()
{
    OwnedDataset data;

    foreach (id; 1L .. 7L)
    {
        OwnedNode node;
        node.id = id;
        node.location = LocationView(id * 10, id * 100);
        data.nodes ~= node;
    }

    OwnedWay a;
    a.id = 10;
    a.nodes ~= OwnedNodeRef(1);
    a.nodes ~= OwnedNodeRef(2);
    a.nodes ~= OwnedNodeRef(3);
    data.ways ~= a;

    OwnedWay b;
    b.id = 11;
    b.nodes ~= OwnedNodeRef(1);
    b.nodes ~= OwnedNodeRef(4);
    b.nodes ~= OwnedNodeRef(3);
    data.ways ~= b;

    OwnedWay inner;
    inner.id = 12;
    inner.nodes ~= OwnedNodeRef(5);
    inner.nodes ~= OwnedNodeRef(6);
    inner.nodes ~= OwnedNodeRef(5);
    data.ways ~= inner;

    OwnedRelation relation;
    relation.id = 20;
    relation.tags ~= OwnedTag(bytes("type"), bytes("multipolygon"));
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        bytes("outer"));
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        11,
        bytes("outer"));
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        12,
        bytes("inner"));
    data.relations ~= relation;

    OwnedDatasetIndex index;
    DatasetValidationIssue issue;
    assert(index.build(data, issue));

    auto area = assembleMultipolygon(
        data,
        index,
        data.relations[0]);

    assert(area.state == AreaAssemblyState.complete);
    assert(area.outerRingCount == 1);
    assert(area.innerRingCount == 1);
    assert(area.rings[0].role == AreaRingRole.outer);
    assert(area.rings[0].closed);
    assert(area.rings[0].segments.length == 2);
    assert(area.rings[0].segments[1].reversed);

    OwnedWay closed;
    closed.id = 30;
    closed.nodes ~= OwnedNodeRef(1);
    closed.nodes ~= OwnedNodeRef(2);
    closed.nodes ~= OwnedNodeRef(1);

    auto single = assembleClosedWayArea(data, index, closed);
    assert(single.complete);
    assert(single.outerRingCount == 1);
}
