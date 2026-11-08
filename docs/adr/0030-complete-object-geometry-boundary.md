# ADR 0030: complete OSM objects stay OSM-native at the geometry boundary

- Status: Accepted
- Date: 2026-11-06
- Related: #134, #135, #136, #138
- References:
  - ADR 0002 exact coordinate representation
  - ADR 0003 borrowed and owned representations
  - ADR 0028 dataset/reference validity
  - ADR 0029 topology resolution and closure

## Context

M15 resolves OSM identities and graph relationships. M16 needs a higher layer
for consumers that want a Way with resolved Node locations, a Relation with
resolved typed members, exact bounds, closed-Way interpretation, and later OSM
area/multipolygon assembly.

That layer must not turn osm-d into a generic geometry engine.

The current stable geo-d API is a deliberately coordinate-system-agnostic
Euclidean geometry library. Its Point2!long, Bounds2!long, Polyline2View!long
and LinearRing2View!long types can represent integer coordinate pairs exactly,
but geo-d intentionally assigns no longitude/latitude, CRS, geographic or
geodetic semantics to them.

osm-d already owns exact geographic OSM coordinates through LocationView using
signed nanodegrees.

## Decision

### Keep the public complete-object model OSM-native

osm-d does not take a direct geo-d dependency for M16 complete objects or area
assembly.

The core representation continues to expose:

- OSM IDs and element types;
- LocationView for exact latitude/longitude semantics;
- ordered Way Node references;
- ordered Relation members and roles;
- explicit resolution/completeness state.

A direct dependency merely to reuse Point2 or Bounds2 would couple the OSM
semantic model to a coordinate-system-neutral library without removing any
domain logic.

### Focused facades

M16 uses two focused layers:

- osm.complete — resolved/complete Way and Relation projections plus OSM-native
  location/bounds helpers;
- osm.area — OSM area and multipolygon member/ring assembly.

osm.topology remains the lower identity/reference graph layer.

Neither new layer is added to the curated import osm root automatically.

### Borrowed views are the default complete-object form

For OsmStore, complete-object operations return borrowed projections over the
store and its existing indexes.

They:

- preserve source order and duplicate references;
- resolve lazily;
- do not deep-copy Nodes, Ways or Relations;
- do not hide a second object graph;
- are invalidated by structural store mutation under the same contract as
  existing store views/ranges.

For OwnedDataset, complete-object operations borrow the dataset arrays and use
an explicit OwnedDatasetIndex. The index must satisfy the M15 invalidation
contract.

### No separate owning complete-object graph in the initial M16 API

Durable OSM ownership already exists through OwnedNode, OwnedWay,
OwnedRelation and OwnedDataset.

The first M16 API therefore does not introduce OwnedCompleteWay or
OwnedCompleteRelation containers that duplicate source objects and child
objects.

A consumer that needs durable independent data may deep-copy the source owned
model or explicitly copy the coordinate/member projection it needs.

If later real consumers require a durable resolved snapshot, that is a separate
API decision with explicit allocation rather than an implicit property of
resolution.

### Partial and invalid references remain explicit

Complete-object traversal does not fetch, repair or drop missing objects.

Per-reference state follows the M15 distinction:

- resolved;
- unresolved positive/server reference;
- unresolved local/negative reference;
- zero reference;
- invalid Relation member type.

An object may therefore be fully resolved or incomplete. Structurally invalid
reference states remain distinguishable from ordinary partial-extract absence.

For OsmStore, a tombstoned target is never exposed as a live resolved object.
Dataset validation remains the authoritative layer for distinguishing a known
deleted target from an external omission.

### Exact coordinates remain LocationView nanodegrees

No complete-object operation converts coordinates to double implicitly.

LocationView remains the semantic coordinate value and preserves signed
nanodegrees exactly.

When a consumer chooses to enter Euclidean geometry space, the conventional
mapping is explicit:

- x = longitudeNanodegrees;
- y = latitudeNanodegrees.

That mapping is an adapter/conversion step, not an OSM semantic reinterpretation.

### OSM-native bounds

M16 may expose an OSM location-bounds value with exact signed nanodegree
minimum/maximum latitude and longitude.

Bounds computation:

- uses resolved Node locations;
- performs no projection;
- performs no dateline wrapping or geodesic interpretation;
- reports incomplete input explicitly when required locations are unresolved;
- distinguishes empty from non-empty bounds.

It is not a replacement for geo-d Bounds2 after a consumer has chosen a
Euclidean coordinate interpretation.

### Closed-Way detection is identity-based

A Way is syntactically closed when it has at least two Node references and the
first and last OSM Node IDs are equal.

This test does not imply that the Way is a valid polygon or OSM area.

Minimum ring cardinality, distinct vertices, self-intersection and polygon
validity are separate area/geometry concerns.

### Geometry materialization is explicit

Complete-object traversal and exact OSM bounds do not allocate merely to expose
resolved coordinates.

The default geometry-ready interface is a borrowed ordered sequence of
LocationView values/resolution records.

If a consumer needs contiguous geo-d Point2!long storage, it explicitly maps
or copies into caller-owned storage. A small adapter may be added later if
repeated consumer code justifies it, but it must remain explicit and must not
make geo-d a dependency of the OSM semantic core by default.

Data-dependent M16 area assembly may allocate owning result/workspace storage
because ring construction itself is a new object. Such allocation must be
documented and must not be confused with generic polygon computation.

### Generic geometry remains outside osm-d

osm-d owns:

- OSM reference/member interpretation;
- Way Node ordering;
- exact OSM locations;
- closed-Way identity semantics;
- OSM-native bounds;
- multipolygon member roles and chain/ring assembly;
- incomplete/ambiguous assembly diagnostics.

geo-d owns:

- Euclidean point/segment/polygon value semantics;
- generic bounds after conversion;
- orientation/intersection;
- ring/polygon validation;
- area;
- point-in-polygon;
- clipping/overlay/simplification.

geodesy-d owns projection and geodetic mathematics.

spatial-index-d owns general spatial indexing.

## Target consumer shape

The exact declaration names are finalized in #135, but the intended usage is:

~~~d
import osm.complete;

auto complete = completeWay(store, way);

auto nodes = complete.nodes;
while (!nodes.empty)
{
    auto node = nodes.front;

    if (node.resolved)
    {
        LocationView location = node.location;
        // Exact signed nanodegrees remain available here.
    }
    else
    {
        // Missing/invalid reference is explicit.
    }

    nodes.popFront();
}

assert(complete.isClosed == (way.nodes.length >= 2 &&
                             way.nodes.front.id ==
                             way.nodes.back.id));
~~~

For Euclidean work the conversion is explicit at the consumer boundary:

~~~d
// Conceptual adapter; no implicit osm-d -> geo-d dependency.
Point2!long point = Point2!long(
    location.longitudeNanodegrees,
    location.latitudeNanodegrees);
~~~

## Consequences

Consumers get one OSM-specific assembly layer instead of rebuilding ID lookup,
location extraction and role interpretation.

The common hot path remains borrowed and allocation-free.

Exact OSM coordinates are not silently degraded to floating point.

osm-d remains independently usable without geo-d.

M16 area assembly can hand deterministic OSM-native rings to a consumer that
then chooses geo-d, geodesy-d or another geometry implementation.

## Alternatives rejected

### Depend directly on geo-d and expose Point2/Bounds2 everywhere

Rejected because it would add a dependency mainly for type reuse and would
erase the useful semantic distinction between longitude/latitude and arbitrary
Euclidean x/y coordinates.

### Convert OSM coordinates to double in complete objects

Rejected because exact nanodegree preservation is already part of the osm-d
contract and no metric operation requires conversion at this layer.

### Materialize a deep owning complete-object graph by default

Rejected because it duplicates durable source objects, adds hidden allocation
and invalidates the compact-store ownership model.

### Treat a closed Way as a valid polygon

Rejected because identity closure is only one OSM structural fact; polygon and
area validity require stronger, separate semantics.
