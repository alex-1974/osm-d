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

public import osm.store.compact.store :
    OsmHandle,
    OsmStore,
    StoreElementState,
    StoreError,
    StoreStatus,
    StoreCounts,
    StoreMemoryUsage,
    StoreMetadataView,
    StoreTagView,
    StoreTagRange,
    StoreWayNodeView,
    StoreWayNodeRange,
    StoreRelationMemberView,
    StoreRelationMemberRange,
    StoreNodeView,
    StoreWayView,
    StoreRelationView,
    StoreNodeRange,
    StoreWayRange,
    StoreRelationRange;
