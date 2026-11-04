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
- `docs/RELEASE_BASELINE.md` — v0.2.x release qualification baseline
- `docs/API_STABILITY.md` — supported v0.2.x API and compatibility policy
- `docs/API_V0_2.md` — v0.1 → v0.2 API migration guide
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
dependency "osm-d" version="~>0.2.0"
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

The package remains pre-1.0. v0.2.x preserves the current high-level consumer
surface for the v0.2.x patch line: `import osm;` stays focused on common
OSM/PBF-traversal/store workflows, loss-aware PBF document/write/parallel
facilities live in `osm.pbf`, and XML, osmChange, comparison and upload
validation use focused facades. The exact v0.2.x promise is in
`docs/API_STABILITY.md`; v0.1 -> v0.2 migration is in `docs/API_V0_2.md`.

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

The store returns the common semantic leaf types `MetadataView`, `TagView`,
`NodeRefView` and `RelationMemberView`; only the borrowing ranges are
store-specific. Stable `OsmHandle` lookup remains available for generic/editor
workflows, but a simple typed read no longer needs the two-step
`find(type,id) -> handle -> node/way/relation` sequence.

The PBF input needs to remain alive only for `readPbfStore`; the resulting
store owns its durable semantics and indexes.

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

After a successful OSM diff upload, pass the exact uploaded sequence together
with its format-neutral `UploadResult` back to the store:

```d
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

The existing `PbfReader.nodes/ways/relations` methods remain equivalent
advanced entry points. Natural completion validates the complete file; an
early foreach exit is explicitly a partial traversal.

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

v0.2.1 is the current qualified v0.2.x patch release. Its high-level capabilities
include:

- validated borrowed and parallel-summary PBF reading;
- durable/loss-aware PBF document read and write through `osm.pbf`;
- streaming OSM XML and osmChange read/write;
- deterministic upload-readiness validation;
- compact editable `OsmStore` with typed lookup, stable handles and parent
  indexes;
- direct transactional PBF-to-store construction;
- deterministic store-edit materialization and authoritative diff-upload result
  reconciliation.

The v0.2.x patch line freezes the supported high-level facade/import surface,
parameter names, ownership/lifetime and failure contracts described in
`docs/API_STABILITY.md`. It does not freeze low-level wire/codec/store
implementation modules, a persistent store format, concurrent store mutation,
rendering, spatial indexing, network/OAuth policy or changeset lifecycle.
`docs/RELEASE_BASELINE.md` records the evidence behind release claims.

Literal JOSM-export provenance remains tracked separately in #85 as evidence
hardening; it is not a semantic/API blocker for v0.2.x.

The repository was renamed from `d-osm` to `osm-d` during the coordinated
workspace reorganization on 2026-09-18. The repository and DUB package use the
`osm-d` name.
