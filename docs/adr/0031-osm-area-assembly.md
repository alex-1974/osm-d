# ADR 0031: OSM area assembly is identity-based and ambiguity-preserving

- Status: Accepted
- Date: 2026-11-06
- Related: #136, #138
- References:
  - ADR 0028 dataset/reference validity
  - ADR 0029 topology resolution and closure
  - ADR 0030 complete-object and geometry boundary
  - OpenStreetMap multipolygon model
  - libosmium area assembler as independent behavioral reference

## Context

M15 resolves OSM graph identities and M16 complete-object projections expose
resolved Nodes, Ways and Relations. Consumers still need one reusable OSM
domain layer that turns:

- a structurally closed Way; or
- a type=multipolygon Relation whose Way members may be fragmented and
  differently directed

into closed outer/inner rings.

This operation is not generic polygon computational geometry. The hard domain
facts are OSM Node identity, Relation member roles, fragmented Way membership,
Way direction independence, partial extracts and source provenance.

Current OSM multipolygon guidance states that outer/inner Way members must form
closed chains, that Way direction does not define the ring, and that Relation
member order does not define the ring. Missing/empty roles are deprecated and
should not be relied on. More than two available unclosed Ways meeting at one
endpoint makes purely topological reconstruction non-unique in the ordinary
case.

libosmium independently demonstrates a useful separation: graph assembly and
role checking are distinct concerns rather than one generic polygon algorithm.

## Decision

### Focused facade

OSM area assembly is exposed through:

~~~d
import osm.area;
~~~

It remains outside the curated import osm root.

### Closed Way assembly is structural, not tagging inference

assembleClosedWayArea accepts a Way that the caller has already decided should
be treated as an area.

osm-d does not maintain a complete tagging ontology that tries to infer whether
every arbitrary closed Way is linear or areal.

The function therefore checks structural ring closure only. Polygon validity is
a separate geometry concern.

### Multipolygon members are strict Way members with explicit roles

assembleMultipolygon requires the source Relation to contain
type=multipolygon.

Accepted member roles are exactly:

- outer
- inner

Current empty/unknown roles are not guessed.

Node and Relation members are reported as unsupported member types. Nested
Relations are not recursively reinterpreted as multipolygon Ways.

This is deliberate: standard multipolygon geometry is defined by Way members.
Legacy/non-standard structures remain visible as explicit diagnostics instead
of being silently repaired.

### Ring joining uses exact Node identity

Open Way members are connected only when their endpoint OSM Node IDs are equal.

Coordinates are not used to decide connectivity.

This preserves exact OSM graph semantics and makes assembly independent of:

- projection;
- floating-point tolerances;
- coincident-but-distinct Nodes.

### Source Way direction may be reversed

A source Way may be traversed forward or backward while assembling a ring.

The source object is never mutated.

AreaRingSegment records:

- source Way ID;
- source Relation member index when applicable;
- whether the Way was reversed;
- the corresponding assembled vertex span.

### Source member order is not required to be ring order

The assembler discovers the unique next Way from endpoint identity.

For deterministic presentation, a new ring starts from the earliest unused
contributing Relation member of that role. Subsequent members follow graph
connectivity.

Associative containers may be used for membership lookup, but their iteration
order never determines ring order.

### Ambiguity is preserved, not guessed away

If more than one unused same-role Way can continue the current endpoint, the
assembler reports ambiguousJunction and stops assembling that role.

It does not choose a candidate by hash order, member order, coordinate angle or
another hidden heuristic.

This also means unusual touching-ring layouts that require geometric pairing
rather than unique endpoint connectivity are surfaced as ambiguous at this
OSM-graph layer. A higher-level consumer may apply a documented policy if it
needs to support such cases.

### Partial data remains partial

An unresolved positive/server Way member is a partial-data condition.

If an otherwise open chain might be explained by a missing same-role Way, the
chain is reported as incompleteChain rather than intrinsically invalid.

An unresolved positive Node inside a resolved Way does not destroy ring
identity: Node IDs can still close the ring. The corresponding AreaVertex keeps
its resolution state, and AreaRing.locationsComplete is false.

Unresolved local/negative, zero, or invalid references remain invalid rather
than being treated as extract omissions.

Dataset validation remains the stronger authority for known Store tombstones.

### Unclosed complete-data chains are invalid

When all referenced same-role Way members are available and a chain has no
continuation back to its first Node, it is retained as AreaOpenChain and
reported as unclosedChain.

### Duplicate members are explicit

The same Way repeated with the same role is diagnosed as duplicateMember and
is not silently assembled twice.

### Assembly output is owning

Assembly creates a new ring/path structure and therefore returns owning dynamic
arrays.

AreaRing contains:

- ordered AreaVertex values;
- ordered AreaRingSegment provenance;
- role;
- exact copied LocationView nanodegrees where resolved;
- locationsComplete.

AreaOpenChain retains equivalent provenance for failed/incomplete chains.

The result remains valid after borrowed source-view invalidation.

### Geometry remains outside osm-d

The assembler does not determine:

- ring simplicity;
- self-intersection;
- outer/inner containment;
- ring orientation;
- overlapping rings;
- polygon area;
- point-in-polygon;
- clipping/overlay;
- projection or geodesic meaning.

Those operations remain in geo-d or geodesy-d after an explicit consumer
conversion, as defined by ADR 0030.

## State model

AreaAssemblyState is an aggregate severity:

- complete — all requested rings assembled and all required objects/locations
  are resolved;
- partial — positive/server references are omitted from the available dataset;
- ambiguous — the available OSM endpoint graph has more than one continuation;
- invalid — the available complete graph violates the supported multipolygon
  structural contract.

AreaAssemblyIssue[] retains the detailed reasons. A result can therefore keep
successfully assembled rings while also exposing incomplete or invalid
components.

## Consequences

A renderer/editor gets deterministic OSM ring assembly without implementing its
own Way-joining logic.

Exact Node identity and nanodegree coordinates are preserved.

No generic geometry dependency is added.

The public API can represent real partial extracts without pretending that
missing data proves invalidity.

Unusual topology is not silently normalized into one arbitrary polygon.

## Alternatives rejected

### Join by coordinate equality

Rejected because distinct OSM Nodes can share coordinates, and Node identity is
the actual graph contract.

### Normalize every ring orientation during assembly

Rejected because orientation is a geometry convention, not required to recover
the OSM member graph.

### Guess missing outer/inner roles

Rejected because current multipolygon roles are expected to be explicit and
guessing would hide data quality problems.

### Recurse into Relation members

Rejected for the initial contract because multipolygon geometry is defined by
Way members and nested Relation interpretation would create a second,
underspecified graph language.

### Pick an arbitrary candidate at multiply-connected endpoints

Rejected because the result would depend on a hidden policy and could change
with unrelated implementation details.
