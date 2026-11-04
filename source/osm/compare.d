/**
 * Consumer-facing semantic comparison helpers.
 *
 * These helpers compare OSM/change semantics independent of serialization.
 * PBF-specific preservation and HeaderBlock comparisons live in `osm.pbf`.
 */
module osm.compare;

public import osm.model.compare :
    sameOsmSemantics,
    sameChangeSemantics;
