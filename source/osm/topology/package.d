/**
 * Consumer-facing OSM topology and reference-resolution API.
 *
 * This facade owns graph identity/reference traversal only. Complete object
 * materialization and geometry assembly remain separate layers.
 */
module osm.topology;

public import osm.topology.resolution :
    ReferenceResolutionState,
    StoreResolvedNodeRef,
    StoreResolvedRelationMember,
    StoreResolvedNodeRefRange,
    StoreResolvedRelationMemberRange,
    OwnedDatasetIndex,
    OwnedResolvedNodeRef,
    OwnedResolvedRelationMember,
    OwnedResolvedNodeRefRange,
    OwnedResolvedRelationMemberRange,
    resolveNodes,
    resolveMembers;


public import osm.topology.closure :
    TopologyTraversalError,
    TopologyTraversalLimits,
    TopologyTraversalStatus,
    TopologyTraversalWorkspace,
    StoreChildVisit,
    OwnedChildVisit,
    StoreParentVisit,
    OwnedParentVisit,
    walkRelationClosure,
    walkParentClosure;
