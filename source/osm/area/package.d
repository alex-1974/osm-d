/**
 * Consumer-facing OSM area and multipolygon assembly.
 *
 * This facade assembles OSM rings by Node identity and preserves OSM-specific
 * roles/provenance. Generic polygon computation remains outside osm-d.
 */
module osm.area;

public import osm.area.assembly :
    AreaRingRole,
    AreaAssemblyState,
    AreaAssemblyIssueKind,
    AreaVertex,
    AreaRingSegment,
    AreaRing,
    AreaOpenChain,
    AreaAssemblyIssue,
    AreaAssemblyResult,
    assembleClosedWayArea,
    assembleMultipolygon;
