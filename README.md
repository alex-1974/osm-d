# osm-d

`osm-d` is a standalone OpenStreetMap data library for D. It is being built as
a reusable component for a future OSM editor, but its public design is not tied
to that editor.

The library has two non-negotiable goals:

1. **Data integrity.** OSM data must never be silently dropped, repaired,
   normalized or approximated. If an operation cannot be performed without
   information loss, it must fail explicitly.
2. **Performance and scalability.** City-scale datasets must be processable in
   reasonable time and memory. Streaming, bounded memory, parallel PBF
   decoding, allocation discipline and reproducible benchmarks are part of the
   architecture from the beginning.

A third rule follows from both:

3. **Measure, do not assume.** Performance choices are benchmarked against
   strong reference implementations; compatibility choices are checked against
   specifications and real-world OSM behavior.

## Scope

The current library scope includes:

- the OSM object model: nodes, ways, relations, tags and metadata;
- streaming and owned representations;
- OSM XML;
- OSM PBF;
- osmChange;
- OSM Editing API diff-upload response parsing;
- Editing API capability discovery for target-aware upload validation;
- structural and semantic validation;
- loss-aware read/write round trips;
- compact stores for larger editable datasets;
- utilities needed by OSM tooling without pulling in editor/UI concerns.

The parser is not a renderer, GUI toolkit, spatial database or editor history
engine.

## Architecture

The core layers are deliberately separated:

```text
bytes
  -> memory / wire
  -> format codec (PBF, XML, osmChange, Editing API XML)
  -> raw representation
  -> validation
  -> borrowed OSM views
  -> owned model or compact store
  -> application
```

The PBF hot path is push-based and allocation-controlled. D ranges are used at
public pipeline boundaries, not forced through the innermost varint/delta
loops. See `ARCHITECTURE.md` and `docs/adr/0004-streaming-api.md`.

## Project documents

- `ARCHITECTURE.md` — module boundaries and data flow
- `docs/DATA_INTEGRITY.md` — integrity contract
- `docs/PERFORMANCE.md` — performance contract and hot-path rules
- `docs/RELEASE_BASELINE.md` — release qualification baseline/evidence
- `docs/API_STABILITY.md` — supported v0.3.x API and compatibility policy
- `docs/API_V0_2.md` — v0.1 → v0.2 API migration guide
- `docs/API_V0_3.md` — v0.2 → v0.3 API migration guide
- `docs/GETTING_STARTED.md` — consumer-oriented examples
- `docs/BENCHMARKS.md` — benchmark methodology
- `docs/SPEC_MATRIX.md` — specifications, real-world behavior and reference implementations
- `docs/adr/` — architecture decision records
- `ROADMAP.md` — implementation sequence

## Shared workspace context

When this repository is used inside `d-geospatial-workspace`, shared
workspace documents are linked only into `.workspace/`. Repo-root documents
remain repository-specific. The helper `tools/link-workspace-docs.sh` manages
only `.workspace/`.

## Install and build

Add the current standalone release line to a DUB package:

```sdl
dependency "osm-d" version="~>0.3.0"
```

Then build normally:

```bash
dub build
```

For an osm-d checkout, the ordinary development checks are:

```bash
dub build
dub test
```

See `docs/GETTING_STARTED.md` for complete small programs covering PBF
traversal, the editable store, loss-aware PBF rewriting, OSM XML and osmChange.

The reference compiler for release-performance benchmarks is LDC. DMD remains
the fast development/correctness compiler. Fast CI uses DMD 2.111.0 and
LDC 1.41.0; release qualification spans DMD 2.111.0–2.113.0 and
LDC 1.41.0–1.43.0. See `docs/DEVELOPMENT.md` for the compiler-support policy
and canonical checks.

The package remains pre-1.0. v0.3.x preserves the supported high-level
consumer surface for the v0.3 patch line: `import osm;` stays focused on
common semantic/PBF-traversal/store workflows, while specialized format and
Editing API families use focused facades.

v0.3 adds `osm.upload` for successful diff-upload responses and
`osm.capabilities` for dynamic target-server upload limits. The released
v0.3.x line deliberately does not add HTTP/OAuth or changeset lifecycle.
Post-v0.3 M17 now accepts OSM protocol ownership in osm-d (ADR 0032) while
generic HTTP remains in transport-d and OAuth/account/retry policy stays
outside the core. The exact v0.3.x
promise is in `docs/API_STABILITY.md`; migration from v0.2 is in
`docs/API_V0_3.md`.

## Reading an in-memory PBF

The ordinary one-shot path does not require caller-managed scratch storage:

```d
import osm;

struct Handler
{
    ulong nodes;

    void node(scope ref NodeView node) @safe nothrow @nogc
    {
        ++nodes;

        auto tags = node.tags;
        while (!tags.empty)
        {
            TagView tag = tags.front;
            tags.popFront();
        }
    }
}

Handler handler;
auto result = readPbf(pbfBytes, handler);

if (!result.ok)
{
    // result.status identifies the high-level failure.
}
```

For repeated/high-throughput reads, retain `PbfReaderWorkspace` and call
`PbfReader.read` directly; this reuses grown scratch capacity. Borrowed views
remain callback-scoped in both forms.

For a bounded file, memory or remote resource, pass the transport abstraction
instead of materializing the complete encoded PBF:

```d
import osm;
import transport : ByteSource, FileSource, ReadError;

ByteSource source = new FileSource("region.osm.pbf");

PbfReader reader;
PbfReaderWorkspace workspace;
PbfReadSummary summary;
PbfSourceReadStatus status;
Handler handler;

if (!reader.read(source, workspace, handler, summary, status))
{
    if (status.transportError != ReadError.none)
    {
        // byte-resource access failed
    }
    else
    {
        // status.pbf reports malformed/unsupported PBF semantics
    }
}
```

This source overload retains only the current PBF header/blob and reusable
decode scratch. Clean EOF inside an incomplete frame is reported as malformed
PBF; a real ByteSource failure remains a transport error. The existing
whole-buffer overload remains the fastest path when the bytes are already
resident.

A Way exposes ordered references through `way.nodes`; each value is a
`NodeRefView` with an OSM ID and an optional `LocationView` when
`LocationsOnWays` was present.

### Loading an editable store directly from PBF

```d
OsmStore store;
PbfReadSummary summary;
PbfStoreReadStatus readStatus;

if (readPbfStore(pbfBytes, store, summary, readStatus))
{
    StoreNodeView node;
    StoreStatus status;

    if (store.node(123, node, status))
    {
        // node.handle is available when stable editor identity is needed.
    }

    auto parentWays = store.parentWays(123);
    auto parentRelations =
        store.parentRelations(ElementType.node, 123);
}
```

The same direct build accepts a `ByteSource` with
`PbfSourceStoreReadStatus`. This gives a bounded
`ByteSource -> PBF decode -> OsmStore` path: the durable store grows normally,
but the complete encoded PBF is never retained merely because of the parser
API.

The store returns the common semantic leaf types `MetadataView`, `TagView`,
`NodeRefView` and `RelationMemberView`; only the borrowing ranges are
store-specific. Stable `OsmHandle` lookup remains available for generic/editor
workflows, but a simple typed read no longer needs the two-step
`find(type,id) -> handle -> node/way/relation` sequence.

Tag ranges support exact, allocation-free lookup through UFCS-friendly helpers:

```d
if (node.tags.hasTag("name"))
{
    auto name = node.tags.findTag("name");
    if (name.found)
    {
        // name.tag.value borrows the same backing storage as the tag range.
    }
}

if (node.tags.tagEquals("place", "city"))
{
}
```

String arguments are compared as their existing UTF-8 code units. No
normalization, case folding or transcoding occurs. `findTag` returns the first
matching duplicate key; `tagEquals` succeeds when any duplicate occurrence
matches both key and value.

The store's element, child and parent traversal values are ordinary lazy D
InputRanges. They can therefore compose with Phobos without materializing an
intermediate result:

```d
import std.algorithm : filter;

auto namedWays =
    store.ways
         .filter!(way => way.tags.hasTag("name"));

foreach (way; namedWays)
{
    // StoreWayView still borrows the store.
}
```

Phobos composition is lazy and allocation-free, but it is a convenience
surface rather than the maximum-throughput traversal. On the pinned Bremen
qualification, plain `filter` added about 7% for a realistic tag-presence
predicate and substantially more for very cheap predicates. Use a direct
range/`foreach` loop with an inline `if` when traversal is a measured hot
path; see `docs/BENCHMARKS.md` for the evidence.

Copying one of these ranges copies only its cursor state. Every copy still
borrows the same store, and structural store mutation invalidates outstanding
ranges and views.

For the slice overload, PBF input bytes need to remain alive only during
`readPbfStore`. For the ByteSource overload, even that complete encoded buffer
is unnecessary. In both cases the resulting store owns its durable semantics
and indexes.

Loss-aware `PbfDocument` reading remains a separate whole-buffer contract
because raw-source preservation intentionally retains original encoded bytes.
The bounded ByteSource reader does not silently weaken or emulate that
preservation contract.

### Materializing and acknowledging edits

The compact store owns editor-facing lifecycle state. Pending edits can be
materialized explicitly as format-neutral change semantics:

```d
OwnedChangeSequence changes;
StoreStatus status;

if (store.collectChanges(changes, status))
{
    changes.setChangeset(openChangesetId);
    // validate/write/upload the sequence through the focused facades.
}
```

No changeset is invented by the store. Local creates are dependency-ordered;
create-then-delete is omitted; established deletes use the captured baseline
version.

After a successful OSM diff upload, parse the server's `diffResult`
through the focused facade and pass the exact uploaded sequence together with
the resulting format-neutral `UploadResult` back to the store:

```d
import osm.upload;

UploadResult uploadResult;
UploadResultReadStatus resultStatus;

if (!readUploadResult(responseSource, uploadResult, resultStatus))
    return;

if (!store.applyUploadResult(changes, uploadResult, status))
{
    // stale local state or mismatched result; nothing was acknowledged.
}
```

Create/modify acknowledgements keep stable handles, with create IDs remapped
through current Way/Relation references and parent indexes. Confirmed deletes
invalidate their old handles. See
`docs/design/store-change-upload-bridge.md`.

### Parallel validated summary decoding

Parallel summary decoding is specialized PBF functionality:

```d
import osm;
import osm.pbf;

PbfParallelReader reader;
PbfParallelReadOptions options;
options.workerCount = 4;
options.queueCapacity = 8;

PbfReadSummary summary;
PbfReadStatus status;
reader.readSummary(pbfBytes, options, summary, status);
```

The bounded pipeline keeps its current blocking producer-backpressure queue.
`containers-d` v0.3.1 was reviewed, but its `BlockingQueue` deliberately
uses non-blocking producer admission; replacing the reader queue with
spin/yield would change the scheduling/performance contract merely for reuse.

### Iterating semantic elements with `foreach`

The most discoverable element-specific form is:

```d
foreach (scope ref NodeView node; pbfNodes(pbfBytes))
{
    // borrowed for this iteration body
}

foreach (scope ref WayView way; pbfWays(pbfBytes))
{
    // way.nodes yields NodeRefView
}

foreach (scope ref RelationView relation; pbfRelations(pbfBytes))
{
}
```

When a streaming consumer wants only matching elements, use the push-filter
adapter rather than materializing an intermediate result:

```d
bool hasHighway(scope ref WayView way) @safe nothrow @nogc
{
    return way.tags.hasTag("highway");
}

auto highways = pbfWays(pbfBytes).where!hasHighway;
foreach (scope ref WayView way; highways)
{
    // matching borrowed Way only
}
assert(highways.status.ok);
assert(highways.completed);
```

`where!` remains an `opApply`/foreach adapter, not a Phobos InputRange. It
does not materialize elements or widen borrowed lifetimes. The predicate is
applied after enough PBF work has been performed to produce a valid semantic
element, so filtering does not promise protobuf-field predicate pushdown or
avoid required framing/decompression/validation.

The existing `PbfReader.nodes/ways/relations` methods remain equivalent
advanced entry points. Natural completion validates the complete file; an
early foreach exit, including from a filtered traversal, is explicitly a
partial traversal.

Loss-aware PBF documents, raw preservation, writing and PBF-specific semantic
comparison are grouped under `import osm.pbf;` rather than expanding the
ordinary package root.

## Streaming OSM XML

Ordinary OSM XML uses the same owned Node/Way/Relation model as PBF. The
consumer-facing facade is `osm.xml`; XML parsing details remain internal.
Byte resources come from `transport-d`.

```d
import osm.xml;
import transport.source : MemorySink, MemorySource;

const(ubyte)[] bytes = ...;
auto source = new MemorySource(bytes);

OsmXmlDocument document;
OsmXmlReadStatus readStatus;

if (!readOsmXmlDocument(source, document, readStatus))
{
    // readStatus reports transport, XML syntax, unsupported-content,
    // precision, or structural failures explicitly.
}

auto sink = new MemorySink();
OsmXmlWriter writer;
OsmXmlWriteStatus writeStatus;

if (!writer.write(document, sink, writeStatus))
{
    // Ordinary OSM XML cannot represent every semantic extension. For
    // example, Way-node LocationsOnWays coordinates fail explicitly.
}
```

`OsmXmlReader.read` is the bounded streaming boundary when complete
materialization is not wanted: it retains only parser state plus one owned OSM
object at a time before invoking the consumer callback. The convenience
`readOsmXmlDocument` deliberately materializes the whole dataset.

Coordinates are accepted only when they are exactly representable by the
current signed-nanodegree semantic location. XML values with non-zero precision
beyond nine decimal places fail with `OsmXmlReadError.precisionLoss`; they are
never rounded silently. Known document-level JOSM metadata such as
`upload="never"` is preserved. JOSM editor-only element actions such as
`action="modify"` remain outside the ordinary XML dataset model and fail
closed. M5 qualifies the supported JOSM-/iD-compatible semantic interchange
path; literal JOSM-export provenance is preserved separately as evidence issue
#85.

## osmChange 0.6

Edit interchange uses the format-neutral `OwnedChangeSequence`; XML action
groups are only serialization. The supported facade is `osm.osmchange`.

```d
import osm.osmchange;
import transport.source : MemorySink, MemorySource;

const(ubyte)[] bytes = ...;
auto source = new MemorySource(bytes);

OsmChangeDocument document;
OsmChangeReadStatus readStatus;
if (!readOsmChangeDocument(source, document, readStatus))
{
    // malformed XML, incomplete create/modify objects, unsupported content,
    // precision loss, or transport errors are reported explicitly.
}

auto sink = new MemorySink();
OsmChangeWriter writer;
OsmChangeWriteStatus writeStatus;
if (!writer.write(document, sink, writeStatus))
{
    // No partial semantic object is silently converted into a modify.
}
```

Entry order is preserved. Consecutive operations may share one XML action
section, but the writer opens a new section whenever the action changes, so
`create -> modify -> delete -> create` stays in that order. The delete
`if-unused` policy is carried explicitly per entry and is never injected.

Create and modify entries must contain complete object state. Delete may carry
a complete object or only identity plus metadata. For an empty delete Way or
Relation the XML syntax cannot distinguish a complete empty object from a
minimal deletion; the reader therefore uses the conservative
`ChangeObjectState.identityOnly` representation instead of inventing
completeness.

Metadata is preserved when present. In particular, the reader/writer does not
invent a missing version or changeset on deletes. Whether an otherwise
representable change is valid for an OSM API upload is a stronger validation
contract handled separately by the modification-validation layer.

## Dataset/reference validation

Dataset integrity is weaker than uploadability and stronger than merely parsing
individual elements. Use `osm.validate` to state whether the loaded data is
expected to be complete or intentionally partial:

```d
import osm.validate;

DatasetValidationIssue issue;

if (!validateDataset(
        dataset,
        DatasetValidationMode.complete,
        issue))
{
    // issue identifies the first invalid identity/reference.
}
```

`DatasetValidationMode.complete` requires every Way node reference and
Relation member to resolve to a correctly typed local object.
`DatasetValidationMode.partial` permits unresolved **positive** IDs from an
extract/API subset, but still rejects unresolved negative/local IDs and zero
references.

Relation cycles are not rejected merely for being cycles; recursive topology
traversal is a separate concern. For `OsmStore`, a reference to a target known
to be tombstoned locally is an explicit `deletedReference`, not an allowed
partial-extract omission.

The same API accepts `OwnedDataset` and `OsmStore`. It does not apply
changeset/version metadata, server capability limits, tag upload rules,
canonical upload coordinate precision, geometry validity or editor policy.

## OSM topology resolution

Use the focused `osm.topology` facade when a consumer needs to navigate OSM
identity/reference graphs rather than merely inspect stored IDs:

```d
import osm.topology;

auto resolved = store.resolveMembers(relation);
while (!resolved.empty)
{
    auto member = resolved.front;

    if (member.resolved)
    {
        // member.target is a stable OsmHandle.
    }
    else
    {
        // unresolvedPositive / unresolvedLocal / zero / invalid type remain
        // explicit; topology traversal never fetches or repairs them.
    }

    resolved.popFront();
}
```

Direct Way/Relation resolution is lazy, preserves source order and duplicates,
and materializes no complete objects. `OsmStore` reuses its existing primary
indexes. For `OwnedDataset`, build an explicit reusable `OwnedDatasetIndex`;
rebuild it after identity/order/insert-remove changes or after Way-node or
Relation-member topology changes.

For recursive graph work, `walkRelationClosure` and `walkParentClosure`
take a reusable `TopologyTraversalWorkspace`, explicit
`TopologyTraversalLimits`, and a visitor callback. Relation child closure is
depth-first and preserves member/Way-node occurrences; Relation identities are
expanded only once so self-reference and longer cycles terminate. Parent
closure returns distinct parent elements and reuses the store's maintained
reverse indexes.

Limit exhaustion is explicit. A visitor-requested early stop is a non-error
partial traversal with `status.completed == false`.

This layer owns OSM graph semantics only. Complete-object materialization,
multipolygon/area assembly, generic geometry, projections, spatial indexing,
rendering and network retrieval of missing objects remain separate concerns.

## Complete OSM objects

Use the focused `osm.complete` facade when ID/reference resolution is not
enough and the consumer needs the resolved semantic child objects themselves:

```d
import osm.complete;

auto full = completeWay(store, way);

auto nodes = full.nodes;
while (!nodes.empty)
{
    auto node = nodes.front;

    if (node.resolved)
    {
        LocationView location = node.location;
        // Exact latitude/longitude nanodegrees; no implicit double conversion.
    }
    else
    {
        // Partial/invalid reference remains explicit.
    }

    nodes.popFront();
}
```

`completeWay` and `completeRelation` are available for `OsmStore` and for
`OwnedDataset` with its explicit `OwnedDatasetIndex`. They are lazy,
preserve source order and duplicates, and do not materialize a second deep
object graph.

`completeStatus` reduces direct child resolution to
`CompleteObjectState.complete`, `.partial` or `.invalid`.
`isClosedWay` performs only the OSM identity test (first and last Node ID are
equal); it does not imply polygon validity.

`locationBounds` computes exact latitude/longitude bounds in signed
nanodegrees from resolved Way Nodes. Resolved locations still contribute when
another child is partial, and the returned completeness status makes that
partial result explicit.

Structural `OsmStore` mutation invalidates outstanding borrowed complete
projections just like ordinary store views. Re-borrow after mutation.
`OwnedDatasetIndex` must be rebuilt after identity/order/insert-remove,
Way-node or Relation-member topology changes.

The complete-object layer does not depend on `geo-d`. A consumer that chooses
Euclidean geometry maps longitude to x and latitude to y explicitly. Generic
polygon/segment algorithms remain outside osm-d.

## OSM area and multipolygon assembly

Use `osm.area` when OSM Way/Relation topology must be assembled into
geometry-ready rings without importing generic polygon algorithms:

```d
import osm.area;

auto area = assembleMultipolygon(store, relation);

if (area.complete)
{
    foreach (ref const ring; area.rings)
    {
        // ring.role is outer or inner.
        // ring.vertices preserve exact Node IDs and LocationView nanodegrees.
        // ring.segments preserve source Way/member provenance and reversal.
    }
}
```

`assembleClosedWayArea` structurally assembles a caller-selected closed Way
as one outer ring. It deliberately does **not** infer from arbitrary tags
whether every closed Way represents an area.

`assembleMultipolygon` requires `type=multipolygon`, Way members and exact
`outer` / `inner` roles. Member order need not match ring order and source
Way direction may be reversed in the owning result without mutating source
data. Connectivity is exact OSM Node identity; coordinates are never used as a
tolerance-based join key.

The result distinguishes:

- `complete` — all requested rings and Node locations are available;
- `partial` — positive/server references are missing from the available
  dataset;
- `ambiguous` — more than one same-role Way can continue an endpoint;
- `invalid` — the available graph violates the supported structural contract.

Failed or incomplete chains remain available as `AreaOpenChain` diagnostics.
`AreaAssemblyIssue` identifies invalid roles/member types, unresolved Ways or
Nodes, duplicates, unclosed chains and ambiguous junctions.

Assembly owns the new ring/path/provenance arrays. Exact `LocationView`
nanodegrees are copied; no implicit floating-point conversion occurs.

This layer does not test polygon simplicity, intersections, containment,
orientation, area, clipping or projection. Those remain explicit downstream
geometry/geodesy operations.


## Changesets

Post-v0.3 M17 provides a focused Changeset semantic/XML facade:

```d
import osm.changeset;
import osm : OwnedTag, ownBytes;
import transport.source : MemorySink, MemorySource;

ChangesetTagRequest request;
request.tags ~= OwnedTag(
    ownBytes(cast(const(ubyte)[]) "created_by"),
    ownBytes(cast(const(ubyte)[]) "osm-d"));
request.tags ~= OwnedTag(
    ownBytes(cast(const(ubyte)[]) "comment"),
    ownBytes(cast(const(ubyte)[]) "Improve footpaths"));

auto sink = new MemorySink();
ChangesetWriteStatus writeStatus;
if (!writeChangesetTagRequest(request, sink, writeStatus))
{
    // transport/XML output failure
}

// A GET/query response is parsed separately into server-owned semantics.
OwnedChangeset changeset;
ChangesetReadStatus readStatus;
auto source = new MemorySource(responseBytes);
if (!readChangeset(source, changeset, readStatus))
{
    // transport/XML/semantic response failure
}
```

`OwnedChangeset` keeps ID, open state, creation/closure timestamps, owner,
optional exact bounds, current change counters, tags and optional discussion
data with explicit presence. An absent discussion is distinct from an
explicitly present empty discussion.

Create/update XML deliberately uses the separate `ChangesetTagRequest` type.
The server owns identity, timestamps, bounds, owner and counters; update tags
are a complete replacement set. The codec performs no HTTP, authentication or
policy decision about when an editor opens, reuses or closes a Changeset.

## Upload validation

Parsing and upload readiness are separate contracts. Use `osm.validate` when
an `OwnedChangeSequence` is intended for an OSM API-style upload:

```d
import osm.validate;

import osm.capabilities;

EditingApiCapabilitiesDocument capabilityDocument;
ApiCapabilitiesReadStatus capabilityStatus;

if (!readEditingApiCapabilities(
        capabilitiesResponseSource,
        capabilityDocument,
        capabilityStatus))
    return;

CapabilityProfile target =
    capabilityDocument.capabilities.validationProfile;

UploadValidationIssue issue;
if (!validateUploadChanges(changes, target, issue))
{
    // issue identifies the first invalid entry and, when relevant,
    // the offending tag/reference/member.
}
```

The validator checks complete create/modify state, signed ID policy, required
changeset/version metadata, exact 1e-7 upload coordinate precision, tag
UTF-8/length/duplicate-key rules, target capability limits, and dependency-safe
negative placeholder references. It validates the supplied order; it does not
silently reorder or repair a sequence.

Positive references need not resolve in the local sequence. Negative/local
references must resolve to an earlier create entry of the correct element type.
The validator uses a temporary hash index proportional to the number of created
placeholders. The changeset element capability applies to the supplied
sequence/request; a caller spanning one changeset across several requests must
also account for prior uploads.

Editor qualification uses independently authored JOSM-/iD-compatible fixtures.
They are semantic compatibility fixtures, not claimed byte-for-byte exports
from either editor. XML whitespace, quote style, attribute order, action-group
layout, and writer generator strings may legitimately differ after a round
trip.

## Release status

v0.3.0 extends the qualified v0.2.1 base with two focused Editing API
response/policy facades. Its high-level capabilities include:

- validated borrowed and parallel-summary PBF reading;
- durable/loss-aware PBF document read and write through `osm.pbf`;
- streaming OSM XML and osmChange read/write;
- deterministic upload-readiness validation;
- compact editable `OsmStore` with typed lookup, stable handles and parent
  indexes;
- direct transactional PBF-to-store construction;
- deterministic store-edit materialization and authoritative diff-upload result
  reconciliation;
- bounded OSM API diffResult parsing through `osm.upload`;
- bounded Editing API capability discovery through `osm.capabilities`.

The v0.3.x patch line freezes the supported high-level facade/import surface,
parameter names, ownership/lifetime and failure contracts described in
`docs/API_STABILITY.md`. It does not freeze low-level wire/codec/store
implementation modules, a persistent store format, concurrent store mutation,
rendering, spatial indexing, network/OAuth policy or changeset lifecycle.
`docs/RELEASE_BASELINE.md` records the evidence behind release claims.

Literal JOSM-export provenance remains tracked separately in #85 as evidence
hardening; it is not a semantic/API blocker for v0.3.x.

The repository was renamed from `d-osm` to `osm-d` during the coordinated
workspace reorganization on 2026-09-18. The repository and DUB package use the
`osm-d` name.
