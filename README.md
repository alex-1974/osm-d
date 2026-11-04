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

The v0.1 release scope includes:

- the OSM object model: nodes, ways, relations, tags and metadata;
- streaming and owned representations;
- OSM XML;
- OSM PBF;
- osmChange;
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
  -> format codec (PBF, XML, osmChange)
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
- `docs/RELEASE_BASELINE.md` — v0.1.0 compatibility/performance baseline
- `docs/API_STABILITY.md` — supported v0.1.x API and compatibility policy
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

Add the first standalone release to a DUB package:

```sdl
dependency "osm-d" version="~>0.1.0"
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

The package is pre-1.0 and the first deliberate standalone release is v0.1.0.
`import osm;` is the curated package root for PBF and store workflows; XML,
osmChange and upload validation use the supported `osm.xml`, `osm.osmchange`
and `osm.validate` facades. The v0.1.x source-compatibility promise and
supported direct-import surface are defined in `docs/API_STABILITY.md`.

## Reading an in-memory PBF

The first consumer reader is intentionally streaming and borrowed. The caller
owns the encoded bytes and a reusable workspace; callbacks receive element
views synchronously without materializing an owned OSM model.

```d
import osm;

struct Handler
{
    ulong nodes;

    void node(scope ref NodeView node) @safe nothrow @nogc
    {
        ++nodes;

        OsmId id = node.id;
        auto location = node.location;
        double latitude = location.latitude;
        double longitude = location.longitude;

        // Exact integer coordinates remain available when required:
        long latitudeNanodegrees = location.latitudeNanodegrees;
        long longitudeNanodegrees = location.longitudeNanodegrees;

        auto metadata = node.metadata;
        if (metadata.hasVersion)
            int versionNumber = metadata.versionNumber;
        if (metadata.hasUserId)
            int userId = metadata.userId;
        if (metadata.hasUsername)
            auto username = metadata.username;

        auto tags = node.tags;
        while (!tags.empty)
        {
            TagView tag = tags.front;
            const key = tag.key;
            const value = tag.value;
            tags.popFront();
        }
    }
}

const(ubyte)[] pbfBytes = ...;

PbfReader reader;
PbfReaderWorkspace workspace;
Handler handler;
PbfReadSummary summary;
PbfReadStatus status;

if (!reader.read(pbfBytes, workspace, handler, summary, status))
{
    // status.error is the stable high-level category.
    // blockSequence/blockOffset identify the affected file block.
}
```

A handler may omit `node`, `way`, or `relation` when that element kind is
not needed. `PbfReader` delivers one concrete semantic `NodeView` for both
regular Node and DenseNodes encoding. The callback-scoped `NodeView` is
deliberately non-copyable; copy the semantic values or ranges that need to be
retained during the callback instead. `node.tags` returns an independent
zero-allocation borrowed range, so advancing that range does not mutate the
codec-owned node view. Relation members are format-independent at the consumer
boundary: each member exposes
`ElementType type`, `OsmId id`, and borrowed role bytes without PBF
StringTable IDs. Tags from regular elements and DenseNodes expose the same
format-independent `TagView` containing only borrowed key/value bytes; PBF
StringTable IDs remain below the consumer boundary. Way callbacks expose ordered
node references through `way.nodes`: each `WayNodeView` carries the referenced `OsmId` and, when
the input provides `LocationsOnWays`, an optional `LocationView`. Consumers
therefore do not need to zip PBF reference and coordinate columns themselves.
The remaining semantic-view unification is tracked separately from the reader
orchestration.

### Loading an editable store directly from PBF

Consumers that need durable random access can construct the compact store
directly from the validated PBF stream:

```d
import osm;

const(ubyte)[] pbfBytes = ...;

OsmStore store;
PbfReadSummary summary;
PbfStoreReadStatus status;

if (!readPbfStore(pbfBytes, store, summary, status))
{
    if (!status.pbf.ok)
    {
        // PBF/framing/semantic decode failure.
    }
    else
    {
        // The file decoded, but editable-store semantics were rejected.
        // Inspect status.store.
    }
}
else
{
    OsmHandle node;
    if (store.find(ElementType.node, 123, node))
    {
        StoreNodeView view;
        StoreStatus storeStatus;
        if (store.node(node, view, storeStatus))
        {
            // view borrows from the durable store, not from pbfBytes.
        }
    }

    auto parentWays = store.parentWays(123);
    auto parentRelations =
        store.parentRelations(ElementType.node, 123);
}
```

The input bytes need to remain alive only for the call. On success the store
owns all semantic state, primary indexes and parent indexes. No
`PbfDocument` or `OwnedDataset` object graph is materialized. The selected M6
construction path is single-writer with one reusable reader workspace; see ADR
0024 for the parallel-staging decision and city-scale evidence.

### Parallel validated summary decoding

When only complete-file validation and aggregate counts are required,
`PbfParallelReader` can decode independent OSMData blocks concurrently
without exposing borrowed element views across worker threads:

```d
PbfParallelReader reader;
PbfParallelReadOptions options;
options.workerCount = 4;
options.queueCapacity = 8;

PbfReadSummary summary;
PbfReadStatus status;

if (!reader.readSummary(pbfBytes, options, summary, status))
{
    // status identifies the earliest failing file block.
}
```

Framing and HeaderBlock validation remain serial. OSMData jobs then enter a
fixed-capacity producer/worker queue. Jobs borrow immutable Blob slices from
the already-loaded input, while each worker owns and reuses one
`PbfReaderWorkspace` for decompression and block decode. All workers join
before `readSummary` returns.

This first parallel API is intentionally summary-only. It does not invoke one
arbitrary consumer handler concurrently and does not materialize semantic
elements merely to extend worker-buffer lifetimes. `PbfReader.read` remains
the ordered direct-sink API; ordered parallel element delivery is a separate
future step.

Zero-valued options select practical defaults: available CPU count for workers
and one queued job slot per worker.

### Iterating semantic elements with `foreach`

`PbfReader.nodes`, `PbfReader.ways`, and `PbfReader.relations` provide
idiomatic D `foreach` adapters without materializing owned element
collections:

```d
PbfReader reader;

auto nodes = reader.nodes(pbfBytes);
foreach (scope ref NodeView node; nodes)
{
    // The view is borrowed for this iteration body.
    if (node.id == wantedId)
        break;
}

auto ways = reader.ways(pbfBytes);
foreach (scope ref WayView way; ways)
{
    // Semantic tags, metadata, and ordered way.nodes remain borrowed.
}

auto relations = reader.relations(pbfBytes);
foreach (scope ref RelationView relation; relations)
{
    // Semantic tags, metadata, and relation.members remain borrowed.
}
```

After traversal, inspect the adapter's `status` and `completed` properties.
A natural traversal to end-of-file has `status.ok == true` and
`completed == true`. A consumer `break`, enclosing `return`, or outer
`goto` stops parsing immediately and leaves `completed == false`; the
unvisited file suffix is then deliberately not validated. Decode failures also
leave `completed == false`, with the failure reported through `status`.

These adapters use D's `opApply` protocol rather than pretending the
synchronous push decoder is a resumable Phobos InputRange. Complete traversal
retains the same whole-file validation scope as `PbfReader.read`, including
validation of element kinds that are not yielded by the selected adapter.

The direct sink API remains the performance-critical core. The node foreach
adapter has no per-node materialization and was qualified against the direct
sink on the pinned Bremen workload with LDC 1.41.0: median deltas were
`+0.77%` for core node access and `-0.21%` for tag traversal, treated as
performance parity.

Way and Relation foreach adapters preserve the same semantic results but carry
a measured convenience cost on the same city workload. Final clean-candidate
medians were `+5.23%` for Way core access, `+4.63%` for full Way traversal,
`+4.84%` for Relation core access, and `+5.21%` for full Relation
traversal. Consumers that need maximum whole-file throughput should therefore
prefer the direct sink API; the foreach adapters trade about five percent on
this workload for idiomatic element-specific traversal.

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

## Upload validation

Parsing and upload readiness are separate contracts. Use `osm.validate` when
an `OwnedChangeSequence` is intended for an OSM API-style upload:

```d
import osm.validate;

CapabilityProfile target;
target.maximumWayNodes = 2_000; // supply values from target-server policy

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

v0.1.0 is the first deliberately qualified standalone release line. Its
supported high-level capabilities are:

- validated borrowed and parallel-summary PBF reading;
- durable/loss-aware PBF document read and write;
- streaming OSM XML and osmChange read/write;
- deterministic upload-readiness validation;
- compact editable `OsmStore` with primary and parent indexes;
- direct transactional PBF-to-store construction.

The release does not freeze low-level wire/codec implementation modules, a
persistent store format, concurrent store mutation, rendering, spatial
indexing, or transport policy. See `docs/API_STABILITY.md` for the exact
compatibility boundary and `docs/RELEASE_BASELINE.md` for the evidence behind
release claims.

Literal JOSM-export provenance remains tracked separately in #85 as evidence
hardening; it is not a semantic/API blocker for v0.1.0.

The repository was renamed from `d-osm` to `osm-d` during the coordinated
workspace reorganization on 2026-09-18. The repository and DUB package use the
`osm-d` name.
