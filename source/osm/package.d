/**
 * Public package root for `osm-d`.
 *
 * `import osm;` exposes the common semantic model, borrowed PBF traversal and
 * editable store workflows. Format-specialized loss-aware PBF document/write
 * facilities live in `osm.pbf`; XML, osmChange, upload validation, API
 * upload results and capability discovery use their corresponding focused
 * facades.
 *
 * Editing API response/policy facades remain opt-in: `osm.upload` and
 * `osm.capabilities` are intentionally not re-exported from this root.
 * Raw upload-result values remain available here for store reconciliation;
 * request semantics are classified with `UploadResultEntry.effectFor`.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm;

public import osm.view.element :
    ElementType,
    OsmId;
public import osm.view.location : LocationView;
public import osm.view.metadata : MetadataView;
public import osm.view.node_ref : NodeRefView;
public import osm.view.relation_member : RelationMemberView;
public import osm.view.tag : TagView;

public import osm.model.owned :
    OwnedBytes,
    OwnedTag,
    OwnedMetadata,
    OwnedNodeRef,
    OwnedRelationMember,
    OwnedNode,
    OwnedWay,
    OwnedRelation,
    OwnedDataset,
    ownBytes;

public import osm.model.change :
    ChangeAction,
    ChangeObjectState,
    OwnedChangeEntry,
    OwnedChangeSequence,
    UploadResultEffect,
    UploadResultEntry,
    UploadResult;

public import osm.store :
    OsmHandle,
    OsmStore,
    StoreElementState,
    StoreError,
    StoreStatus,
    StoreCounts,
    StoreMemoryUsage,
    StoreTagRange,
    StoreNodeRefRange,
    StoreRelationMemberRange,
    StoreNodeView,
    StoreWayView,
    StoreRelationView,
    StoreParentWayRange,
    StoreParentRelationRange,
    StoreNodeRange,
    StoreWayRange,
    StoreRelationRange,
    PbfStoreReadStatus,
    readPbfStore;

public import osm.io.pbf.node_view : NodeView;
public import osm.io.pbf.way : WayView;
public import osm.io.pbf.relation : RelationView;

public import osm.io.pbf.reader :
    PbfNodeIterable,
    PbfWayIterable,
    PbfRelationIterable,
    PbfReadError,
    PbfReadStatus,
    PbfReadSummary,
    PbfReadResult,
    PbfReaderWorkspace,
    PbfReader,
    readPbf,
    pbfNodes,
    pbfWays,
    pbfRelations;
