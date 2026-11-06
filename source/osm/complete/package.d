/**
 * Consumer-facing complete OSM object projections.
 *
 * Complete objects enrich M15 topology resolution with the resolved semantic
 * child objects and exact OSM-native locations. Generic geometry remains
 * outside this facade.
 */
module osm.complete;

public import osm.complete.object :
    CompleteObjectState,
    CompleteObjectStatus,
    LocationBounds,
    StoreCompleteNode,
    StoreCompleteNodeRange,
    StoreCompleteWayView,
    StoreCompleteRelationMember,
    StoreCompleteRelationMemberRange,
    StoreCompleteRelationView,
    OwnedElementView,
    OwnedCompleteNode,
    OwnedCompleteNodeRange,
    OwnedCompleteWayView,
    OwnedCompleteRelationMember,
    OwnedCompleteRelationMemberRange,
    OwnedCompleteRelationView,
    completeWay,
    completeRelation,
    isClosedWay,
    completeStatus,
    locationBounds;
