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

Planned scope includes:

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
- `docs/BENCHMARKS.md` — benchmark methodology
- `docs/SPEC_MATRIX.md` — specifications, real-world behavior and reference implementations
- `docs/adr/` — architecture decision records
- `ROADMAP.md` — implementation sequence

## Shared workspace context

When this repository is used inside `d-geospatial-workspace`, shared
workspace documents are linked only into `.workspace/`. Repo-root documents
remain repository-specific. The helper `tools/link-workspace-docs.sh` manages
only `.workspace/`.

## Build

```bash
dub build
dub test
```

The reference compiler for release-performance benchmarks is LDC. DMD remains
the fast development/correctness compiler. Fast CI uses DMD 2.111.0 and
LDC 1.41.0; release qualification spans DMD 2.111.0–2.113.0 and
LDC 1.41.0–1.43.0. See `docs/DEVELOPMENT.md` for the compiler-support policy
and canonical checks.

The package is still pre-1.0. `import osm;` is the curated package root and
now exposes the whole-buffer PBF reader boundary without re-exporting the
low-level codec or wire implementation surface. The supported direct-import
surface and the distinction between semantic API, evolving codec API, and
implementation modules are documented in `docs/DEVELOPMENT.md`.

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
closed; complete JOSM/iD editing interoperability is tracked separately by M5
qualification.

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

## Status

The first substantial PBF implementation slice is in place. Implemented
components include bounded PBF framing/decompression, HeaderBlock capability
handling, PrimitiveBlock layout and StringTable indexing, DenseNodes including
tags and DenseInfo, regular Node, Way, and Relation decoding, and reproducible
microbenchmarks for the current entity hot paths.

DenseNodes scalar hot-path research has progressed through experiments A2-A11b.
The retained A8e implementation reuses the already validated sole DenseNodes
payload for implicit-all-tagless groups, A9a removes a duplicate post-layout
DenseNodes column-length guard under the validated-layout contract, A10a uses
the completed DenseTags preflight to avoid repeating StringTable-ID semantic
validation while partitioning tags during internal emission, and A10b carries
that construction-controlled proof into `DenseTagRange` pair decoding. A11a
applies the same validated-state principle to DenseInfo emission, avoiding
repeated semantic arithmetic and ID-domain checks after complete preflight.
Public defensive validation and StringTable materialization checks remain
intact. A11b investigated reuse of preflight-discovered canonical packed
DenseInfo column locations. Its fixed per-group saving was measurable under
amplification but not robust on the measured real-PBF workload, so the
additional fast path was not retained.
Detailed evidence and rejected alternatives are recorded in
`docs/BENCHMARKS.md`.

The format-independent borrowed `ElementView` identity contract is now in
place, and the codec-owned regular Node, DenseNode, Way, and Relation PBF views
conform to it without changing their specialized representations. The current
PBF vertical slice performs fail-closed structural validation and complete
per-group element preflight before observable sink emission. Dataset/reference
and operation-specific validation remain separate higher layers. The
consumer-facing whole-buffer PBF reader now unifies regular and dense nodes
behind one concrete semantic `NodeView`. Bounded block-parallel validation and
summary decoding are implemented through `PbfParallelReader`; generic ordered
parallel delivery of worker-borrowed element views is intentionally not part of
Phase 3 (ADR 0017). Loss-aware PBF writing, ordinary streaming OSM XML,
and streaming osmChange read/write support are now implemented. Complete edit
validation/editor interoperability qualification and the compact editable store
remain future work.

The repository was renamed from `d-osm` to `osm-d` during the coordinated
workspace reorganization on 2026-09-18. The repository and DUB package now use
the `osm-d` name.
