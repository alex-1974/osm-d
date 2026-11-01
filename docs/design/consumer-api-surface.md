# Consumer API Surface

Status: design proposal

## Purpose

`osm-d` should expose OpenStreetMap concepts and user operations.

PBF, protobuf, validation-pass, wire-layout, StringTable, preflight, packed-field,
cursor, offset, and DenseNodes implementation terminology belongs behind the
consumer boundary unless a consumer has a concrete need for it.

The public API should be understandable to a caller who understands OSM but
does not understand the OSMPBF wire format.

Performance remains a first-class requirement. This design changes the
consumer vocabulary and abstraction boundary; it does not require replacing
the existing zero-copy or allocation-conscious implementation.

## Naming principles

Public names SHOULD answer one of these questions:

- What OSM object is this?
- What semantic data does it contain?
- What operation does the caller want to perform?

Public names SHOULD NOT require knowledge of:

- protobuf field layout;
- packed versus unpacked repeated fields;
- DenseNodes encoding;
- StringTable indexes;
- preflight/validation implementation phases;
- wire cursors or varints;
- internal byte offsets or decode plans.

Technical names remain appropriate for internal implementation code.

## Semantic vocabulary

### Keep

| Current name | Decision | Reason |
|---|---|---|
| `OsmId` | keep | Clear OSM identifier vocabulary |
| `ElementType` | keep | Directly describes node / way / relation |
| `NodeView` | keep | Clear borrowed semantic node |
| `WayView` | keep | Clear borrowed semantic way |
| `RelationView` | keep | Clear borrowed semantic relation |
| `TagView` | keep | Clear OSM tag |
| `RelationMemberView` | keep | Clear OSM relation member |
| `LocationView` | add | Semantic coordinate value shared by nodes and optional way-node locations |
| `WayNodeView` | add | Semantic way-node reference with optional location |

`View` is intentional. It communicates borrowed, non-owning data and therefore
carries useful lifetime information for consumers.

## Rename or reshape

### `InfoView` / `DenseInfoView` -> `MetadataView`

`Info` and `DenseInfo` are protobuf schema/encoding names. They describe the
same OSM element metadata: version, timestamp, changeset, user, and visibility.

The consumer should see one semantic type regardless of whether the source was
a regular `Info` message or a `DenseInfo` column set.

Target vocabulary:

~~~d
struct MetadataView
{
    bool hasVersion;
    int versionNumber;

    bool hasTimestamp;
    long timestampMilliseconds;

    bool hasChangeset;
    long changesetId;

    bool hasUserId;
    int userId;

    bool hasUsername;
    const(ubyte)[] username;

    bool hasVisibility;
    bool visible;
}
~~~

Changeset identifiers are not `OsmId` values because they do not identify a
node, way, or relation. Numeric user ID and username are independently optional
in the source schema and therefore retain independent presence flags. `version`
is a D keyword, so the semantic property is `versionNumber`.

Internal decoding may continue to use separate regular and dense structures,
delta accumulators, raw timestamp values, and StringTable IDs.

Those details should be converted into `MetadataView` before crossing the
consumer boundary.

Implementation note (2026-11-01): the first metadata slice now exposes
`metadata` from regular Node, DenseNodes-backed Node, Way, and Relation views.
It constructs a compact semantic value only when requested. Existing codec
`info` fields remain available during the pre-1.0 transition; the semantic
view does not expose raw PBF timestamp values or StringTable IDs, and username
bytes retain their borrowed representation without inventing a UTF-8 policy.

### Locations

Current public names such as:

~~~d
latNano
lonNano
~~~

describe storage representation rather than the OSM concept.

The public vocabulary should center on a location:

~~~d
struct LocationView
{
    // Exact backing representation remains an implementation decision.
    ...

    @property auto latitude() const;
    @property auto longitude() const;
}
~~~

A node should therefore read naturally:

~~~d
node.location
node.location.latitude
node.location.longitude
~~~

The implementation may continue storing signed nanodegrees internally.

Do not silently replace the exact integer representation with floating-point
storage. A convenience conversion to degrees may be exposed as a property if
benchmarking shows no unwanted cost.

The same `LocationView` should represent optional `LocationsOnWays`
coordinates. Consumers should not need a second coordinate vocabulary merely
because the location originated in a different PBF field.

Implementation note (2026-11-01): the location slice provides this surface
through the concrete semantic `NodeView` delivered by `PbfReader`; optional
Way locations use the same `LocationView`. Exact signed nanodegrees remain
codec backing, while `latitude` / `longitude` convert to degrees only when
requested. Direct codec `latNano` / `lonNano` fields are package-internal at
the ordinary consumer boundary.

### `TagView`

Normal consumers need:

~~~d
tag.key
tag.value
~~~

The following are internal PBF mechanics:

~~~d
keySid
valueSid
~~~

They should not be part of the normal public semantic view.

### Relation members

`RelationMemberType` and `ElementType` currently encode the same semantic
domain and the same node/way/relation values.

The public relation member therefore uses the existing semantic type:

~~~d
struct RelationMemberView
{
    ElementType type;
    OsmId id;
    // Borrowed semantic role value.
    ...
}
~~~

Normal consumers need:

~~~d
member.type
member.id
member.role
~~~

`RelationMemberType` may remain as an internal PBF decoding enum if useful, but
it should not cross the semantic boundary.

The following is internal PBF machinery:

~~~d
roleSid
~~~

Implementation note (2026-11-01): relation-member delivery now uses the
format-independent `osm.view.relation_member.RelationMemberView`. Its public
surface is exactly `ElementType type`, `OsmId id`, and borrowed `role`
bytes. PBF `role_sid` remains local to StringTable validation/materialization,
and the duplicate `RelationMemberType` enum no longer crosses the consumer
boundary.

### Raw provenance

Fields such as:

~~~d
raw
rawOffset
~~~

are useful implementation/debug/provenance mechanisms but should not be part
of the ordinary semantic element API.

If raw provenance later has a demonstrated consumer use case, expose it through
an explicitly named advanced/provenance interface rather than every element.

## Dense nodes

`DenseNodes` is an OSMPBF storage encoding, not a separate OSM object type.

A consumer should not need separate code paths for:

~~~d
NodeView
DenseNodeView
~~~

Both encodings represent OSM nodes.

Target semantic model:

~~~text
regular PBF Node ---\
                     -> NodeView
DenseNodes ---------/
~~~

The optimized DenseNodes parser remains free to use specialized internal
representations and fast paths.

Implementation note (2026-11-01): `PbfReader` now implements this boundary
with one concrete callback-scoped `NodeView`. It is a small non-copyable
borrow over the existing regular or dense codec view; the codec representations
and scalar-only DenseNodes fast path remain specialized. `node.tags` creates
one independent zero-allocation range copy only when tags are requested.

The public result preserves equivalent OSM semantics.

## Semantic tags

Normal element tags and DenseNodes tags are the same OSM concept. Their public
value type is therefore one format-independent `TagView`:

~~~d
struct TagView
{
    const(ubyte)[] key;
    const(ubyte)[] value;
}
~~~

PBF StringTable IDs remain codec state. The PBF ranges may retain the current
key/value IDs internally for validation, diagnostics, and controlled
microbenchmarks, but `tags.front` exposes only the exact borrowed key/value
bytes. No normalization, transcoding, or materialization is introduced.

Implementation note (2026-11-01): both normal `TagRange` and
`DenseTagRange` now return the same semantic `TagView`. The package-root
consumer probe also asserts that `keySid` and `valueSid` are absent from the
semantic type.

## Ranges and way nodes

Range types are useful implementation tools, but the consumer should discover
them through OSM concepts rather than PBF column structure.

Natural properties are:

~~~d
node.tags
way.tags
way.nodes
relation.tags
relation.members
~~~

`TagRange` and `RelationMemberRange` may remain public range value types because
their names already describe semantic OSM collections.

The current Way API exposes two parallel ranges:

~~~d
way.refs
way.locations
~~~

That mirrors PBF storage more than ordinary OSM usage. The preferred semantic
surface is a single ordered node-reference range:

~~~d
struct WayNodeView
{
    OsmId id;

    @property bool hasLocation() const;
    @property LocationView location() const;
}

way.nodes
~~~

For normal OSM PBF data, `WayNodeView.id` is always useful while the location
is usually absent. If `LocationsOnWays` is present, the same range can expose
the corresponding location without requiring callers to zip parallel ranges.

This abstraction must remain lazy and allocation-free. It must not perform
node lookup or geometry construction.

The internal parser may retain separate reference and location columns/ranges
if that is faster.

Consumers should not need to construct any of these ranges manually.

Implementation note (2026-11-01): the first Way-node semantic slice now
exports format-independent `WayNodeView` and exposes `way.nodes` as a lazy,
allocation-free projection over the already validated PBF reference and optional
location ranges. Existing `refs` / `locations` remain available during the
pre-1.0 transition, but the external package-root consumer probe uses
`way.nodes` and no longer needs to zip parallel PBF columns.

## Decoder boundary

The following functions currently expose codec assembly details:

~~~d
decodeNodes
decodeDenseNodes
decodeWays
decodeRelations
~~~

Their signatures require technical objects such as block layouts, group
layouts, StringTable views, sinks, summaries, and PBF status values.

They should become internal building blocks of a higher-level reader API.

Ordinary callers should not need to know whether a node came from `Node` or
`DenseNodes`.

## Reader direction

The target entry point should identify the serialization format at the reader
boundary while keeping all delivered objects semantic.

Preferred top-level type:

~~~d
PbfReader
~~~

`PBF` is appropriate here because it describes the caller-selected input
format. It should not leak into element, metadata, tag, member, or coordinate
names.

The primary hot-path API should use statically dispatched semantic callbacks:

~~~d
struct Handler
{
    void node(scope ref NodeView node) @safe nothrow @nogc;
    void way(scope ref WayView way) @safe nothrow @nogc;
    void relation(scope ref RelationView relation) @safe nothrow @nogc;
}

PbfReader reader = ...;
reader.read(handler);
~~~

This naming matches the OSM domain directly: the caller implements `node`,
`way`, and/or `relation`, not decoder-specific `putDenseNodeScalars`,
`decodeWays`, or protobuf callbacks.

A handler may implement only the element kinds it needs if static dispatch can
support that without runtime overhead.

An iterable/variant convenience layer may be considered later, but it should
not define the performance-critical core API. The core must not force:

- allocation;
- virtual dispatch;
- element materialization;
- tagged-union dispatch;
- copies of borrowed ranges;
- coordinate conversion that the consumer did not request.

Borrowed views remain callback-scoped unless a later ownership API explicitly
provides durable values.

Implementation note (2026-11-01): `PbfReader` now delivers one concrete
semantic `NodeView` for regular Node and DenseNodes encoding through
`void node(scope ref NodeView node)`. The wrapper is deliberately non-copyable
because it borrows the codec-local view only for the synchronous callback.
Requested tag ranges are copied once into an independent borrowed cursor;
advancing them does not mutate the codec-owned range. The measured reader
boundary remains performance-neutral on the pinned Bremen qualification
workload while preserving the specialized decoder hot paths.

## Internal-only candidates

The following names describe implementation mechanisms and should not form part
of the normal external API:

~~~text
PrimitiveBlockLayout
PrimitiveGroupLayout
DenseNodesLayout

StringRef
StringTableView
buildStringTableView

TagValidationSummary
DenseTagValidationSummary
DenseInfoValidationSummary
RelationMemberValidationSummary

validateTags
validateDenseTags
validateDenseInfo
validateRelationMembers

DenseTagNodeCursor
DenseInfoNodeCursor

WayDecodePlan
WayCompactInfo
WayPackedSpan
buildWayDecodePlans
buildWayFromDecodePlan

WireCursor
WireStatus
FieldHeader
WireType
readVarint*
readSVarint*
~~~

Low-level OSMPBF framing types such as Blob and HeaderBlock require a separate
decision: they may remain available as an explicitly advanced PBF API if a
real consumer use case justifies direct framing access, but they should not be
required for ordinary OSM reading.

## Errors

The normal reader boundary should expose errors in terms useful to the caller.

A consumer should be able to determine at least:

- whether reading succeeded;
- whether input is malformed;
- whether a required PBF feature is unsupported;
- where useful, the input location associated with the failure.

Wire-field numbers, varint failure details, and protobuf cursor state are
diagnostic implementation details.

`PbfError` / `PbfStatus` may remain internally rich while the reader provides a
smaller semantic error surface.

## Current-to-target API matrix

| Current consumer-visible name | Target | Action |
|---|---|---|
| `NodeView` | `NodeView` | one concrete reader callback type |
| `DenseNodeView` | `NodeView` | encoding distinction hidden by PbfReader |
| `WayView` | `WayView` | keep semantic name |
| `RelationView` | `RelationView` | keep semantic name |
| `InfoView` | `MetadataView` | rename semantic surface |
| `DenseInfoView` | `MetadataView` | merge semantic surface |
| `TagView.keySid` | internal | hide StringTable ID |
| `TagView.valueSid` | internal | hide StringTable ID |
| `TagView.key` | `TagView.key` | keep semantic value |
| `TagView.value` | `TagView.value` | keep semantic value |
| `RelationMemberType` | `ElementType` | remove duplicate public type |
| `RelationMemberView.roleSid` | internal | hide StringTable ID |
| `RelationMemberView.role` | `RelationMemberView.role` | keep semantic value |
| `NodeView.latNano/lonNano` | `NodeView.location` | expose semantic location |
| `WayLocationView` | `LocationView` | share coordinate vocabulary |
| `WayView.refs` | `WayView.nodes` | expose semantic node references |
| `WayView.locations` | `WayView.nodes[*].location` | fold optional location into node reference |
| `raw` / `rawOffset` | advanced/internal | remove from ordinary element view |
| `decodeNodes` | reader internals | hide assembly API |
| `decodeDenseNodes` | reader internals | hide encoding-specific API |
| `decodeWays` | reader internals | hide assembly API |
| `decodeRelations` | reader internals | hide assembly API |
| `PrimitiveBlockLayout` | internal | hide wire-layout mechanism |
| `PrimitiveGroupLayout` | internal | hide wire-layout mechanism |
| `StringTableView` / `StringRef` | internal | hide PBF lookup mechanism |
| validation/preflight summaries | internal | hide implementation phase |
| `WireCursor` / varint helpers | internal | hide protobuf mechanism |

Implementation note (2026-11-01): the ordinary reader boundary now hides
direct Node nanodegree fields, codec `Info`/`DenseInfo` state, regular
Node/Way/Relation raw payload provenance, and the transitional Way
`refs`/`locations` columns from external consumers. The same representation
remains package-visible to codec tests and benchmarks, so this step changes
visibility rather than data layout or decoding.

## Compatibility direction

There is no released API freeze that requires preserving accidental exposure of
implementation mechanisms.

Before changing visibility or names:

1. add compile-time consumer tests for the intended public surface;
2. add compile-negative tests for implementation names that must become hidden;
3. preserve current semantic tests;
4. benchmark the high-level reader against the current direct decoder path;
5. verify DMD 2.111.0 and LDC 1.41.0;
6. update README/DDOX examples around the consumer API rather than internal PBF
   assembly.

## Initial target surface

Conceptually, a normal `osm-d` user should mainly need to discover:

~~~text
PbfReader

OsmId
ElementType

NodeView
WayView
RelationView

LocationView
WayNodeView
TagView
MetadataView
RelationMemberView
~~~

plus the semantic ranges/properties reachable from those views.

The implementation may contain substantially more code and substantially more
technical names. That complexity should remain below the public boundary.
