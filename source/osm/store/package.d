/**
 * Consumer-facing editable OpenStreetMap store.
 *
 * The public API describes OSM semantics and stable handles. The selected
 * compact representation remains an implementation detail below this module.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.store;

public import osm.view.metadata : MetadataView;
public import osm.view.node_ref : NodeRefView;
public import osm.view.relation_member : RelationMemberView;
public import osm.view.tag : TagView;

public import osm.model.change :
    ChangeAction,
    ChangeObjectState,
    OwnedChangeEntry,
    OwnedChangeSequence,
    UploadResultEffect,
    UploadResultEntry,
    UploadResult;

public import osm.store.compact.store :
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
    StoreRelationRange;

public import osm.store.pbf :
    PbfStoreReadStatus,
    readPbfStore;
