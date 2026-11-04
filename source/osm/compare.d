/**
 * Consumer-facing semantic comparison helpers.
 *
 * These helpers compare OSM/change semantics independent of serialization.
 * PBF-specific preservation and HeaderBlock comparisons live in `osm.pbf`.

 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-04
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT */
module osm.compare;

public import osm.model.compare :
    sameOsmSemantics,
    sameChangeSemantics;
