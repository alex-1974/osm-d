module app;

import osm :
    ElementType,
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
import osm.topology :
    OwnedDatasetIndex,
    ReferenceResolutionState,
    resolveNodes;

void main()
{
    OwnedDataset data;

    OwnedNode node;
    node.id = 1;
    data.nodes ~= node;

    OwnedWay way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(1);
    way.nodes ~= OwnedNodeRef(999);
    data.ways ~= way;

    OwnedRelation relation;
    relation.id = 20;
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        null);
    data.relations ~= relation;

    OwnedDatasetIndex index;
    import osm.validate : DatasetValidationIssue;
    DatasetValidationIssue issue;
    assert(index.build(data, issue));

    auto refs = index.resolveNodes(data.ways[0]);
    assert(refs.front.resolved);
    assert(refs.front.targetIndex == 0);
    refs.popFront();
    assert(refs.front.state ==
        ReferenceResolutionState.unresolvedPositive);

    auto store = new OsmStore();
    StoreStatus status;

    OsmHandle nodeHandle;
    assert(store.add(node, nodeHandle, status));

    OsmHandle wayHandle;
    assert(store.add(way, wayHandle, status));

    StoreWayView wayView;
    assert(store.way(wayHandle, wayView, status));

    auto storeRefs = store.resolveNodes(wayView);
    assert(storeRefs.front.resolved);
    assert(storeRefs.front.target == nodeHandle);
}
