module app;

import osm :
    ElementType,
    LocationView,
    OsmHandle,
    OsmStore,
    OwnedDataset,
    OwnedNode,
    OwnedNodeRef,
    OwnedRelation,
    OwnedRelationMember,
    OwnedWay,
    StoreStatus,
    StoreWayView;
import osm.complete :
    CompleteObjectState,
    LocationBounds,
    completeRelation,
    completeStatus,
    completeWay,
    locationBounds;
import osm.topology : OwnedDatasetIndex;
import osm.validate : DatasetValidationIssue;

void main()
{
    OwnedDataset data;

    OwnedNode node;
    node.id = 1;
    node.location = LocationView(48_000_000_000L, 16_000_000_000L);
    data.nodes ~= node;

    OwnedWay way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(1);
    way.nodes ~= OwnedNodeRef(1);
    data.ways ~= way;

    OwnedRelation relation;
    relation.id = 20;
    relation.members ~= OwnedRelationMember(
        ElementType.node,
        1,
        null);
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        null);
    data.relations ~= relation;

    OwnedDatasetIndex index;
    DatasetValidationIssue issue;
    assert(index.build(data, issue));

    auto fullWay = completeWay(data, index, data.ways[0]);
    assert(fullWay.isClosed);
    assert(completeStatus(fullWay).complete);

    LocationBounds bounds;
    assert(locationBounds(fullWay, bounds).complete);
    assert(!bounds.empty);

    auto fullRelation =
        completeRelation(data, index, data.relations[0]);
    assert(completeStatus(fullRelation).complete);

    auto members = fullRelation.members;
    assert(members.front.resolved);
    assert(members.front.target.node.id == 1);

    auto store = new OsmStore();
    StoreStatus storeStatus;

    OsmHandle nodeHandle;
    assert(store.add(node, nodeHandle, storeStatus));

    OsmHandle wayHandle;
    assert(store.add(way, wayHandle, storeStatus));

    StoreWayView wayView;
    assert(store.way(wayHandle, wayView, storeStatus));

    auto storeWay = completeWay(store, wayView);
    assert(completeStatus(storeWay).state ==
        CompleteObjectState.complete);
}
