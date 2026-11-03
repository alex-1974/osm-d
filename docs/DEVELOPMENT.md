# Development Policy

## Compilers

DMD is suitable for fast edit/build/test cycles. LDC is the reference compiler
for release-performance measurements because the production hot paths are
intended to benefit from LLVM optimization.

During pre-1.0 development, compiler qualification is intentionally split by
branch trust level.

The Fast CI baseline used for every `develop` push and pull request is:

- DMD 2.111.0;
- LDC 1.41.0 using DMD frontend 2.111.0.

The full Release Gate used for promotion/release qualification covers three
frontend generations in both compiler families:

- DMD 2.111.0;
- DMD 2.112.1;
- DMD 2.113.0;
- LDC 1.41.0 using DMD frontend 2.111.0;
- LDC 1.42.0 using DMD frontend 2.112.1;
- LDC 1.43.0 using DMD frontend 2.113.0.

DUB remains fixed at 1.40.0 in CI so compiler qualification does not
simultaneously change the build tool.

No compatibility guarantee is currently made for frontends older than 2.111.
The 2.111 generation is therefore the current tested compatibility floor, while
the two newer generations are release canaries and qualification targets.
Raising the floor remains a deliberate compatibility decision rather than an
incidental consequence of adopting a newer compiler.

The canonical local correctness checks are:

```bash
dub test --compiler=dmd --force
dub test --compiler=ldc2 --force
dub build --compiler=ldc2 --build=release --force
bash tests/run-consumer-compile.sh
tests/run-dip1000-negative.sh
bash tests/fuzz/run-wire-seeds.sh
```

GitHub Actions separates checks by branch trust level.

For pushes to `develop` and pull requests targeting `develop`, Fast CI runs the
supported DMD 2.111.0 and LDC 1.41.0 matrix. Each compiler job runs unit tests,
an external-consumer compile probe through the curated package root, DIP1000
lifetime-negative checks, the deterministic wire malformed-input seed corpus,
and a release build.

For pull requests targeting `main`, pushes to `main`, and release/hotfix
branches, the Release Gate runs the full six-compiler qualification matrix and
reruns the deterministic wire malformed-input seed corpus across the full
compiler matrix and additionally builds the parser decode-count benchmark as a
consumer-facing parser smoke test. This deliberately keeps expensive cross-generation
qualification out of ordinary `develop` commits while requiring it before
release promotion. `main` remains the release line; normal development targets
`develop`.

## Public module surface during pre-1.0

D module visibility and package support are separate concerns. A source module
being directly importable does not by itself make every declaration in that
module part of a compatibility promise.

The current pre-1.0 surface is classified as follows:

- `osm` is the curated package root. It re-exports the consumer-facing
  whole-buffer PBF reader boundary (`PbfReader`, `PbfReaderWorkspace`,
  `PbfNodeIterable`, `PbfWayIterable`, `PbfRelationIterable`,
  `PbfParallelReader`, `PbfParallelReadOptions`, `PbfReadSummary`,
  `PbfReadStatus`, `PbfReadError`) plus the
  format-independent semantic node/way/relation/identity/location/metadata/tag/
  member/way-node vocabulary (`NodeView`, `WayView`, `RelationView`,
  `OsmId`, `ElementType`, `LocationView`, `MetadataView`, `TagView`,
  `RelationMemberView`, `WayNodeView`). `NodeView` is the one concrete
  callback/foreach value type used for regular Node and DenseNodes encoding.
  `PbfNodeIterable`, `PbfWayIterable`, and `PbfRelationIterable` are the
  element-specific convenience adapters returned by `PbfReader.nodes`,
  `PbfReader.ways`, and `PbfReader.relations`; they use `opApply` rather
  than pretending the synchronous decoder is a resumable Phobos InputRange.
  The package root does not re-export the evolving low-level PBF or wire
  implementation surface.
- `osm.view.element`, `osm.view.location`, `osm.view.metadata`,
  `osm.view.tag`, `osm.view.relation_member`, and `osm.view.way_node` are
  supported semantic direct-import APIs. The `ElementType`, `OsmId`,
  structural `isElementView` contract, `LocationView`, `MetadataView`,
  `TagView`, `RelationMemberView`, and `WayNodeView` form the current
  format-independent borrowed semantic boundary described by ADR 0016 and the
  consumer API design. The package-root `NodeView` is callback-scoped and
  deliberately non-copyable; semantic subviews and tag-range copies remain
  ordinary values.
- `osm.model.owned` is the format-independent durable semantic model for
  M4 and later codecs/stores. The curated root exports its owned Node/Way/
  Relation/tag/metadata/member/reference/dataset values. Immutable byte strings
  may share backing storage; mutable child arrays follow normal D aliasing
  semantics and `deepCopy` creates independently mutable arrays.
- `osm.raw.pbf` and `osm.io.pbf.document` form the PBF read/modify/write
  preservation boundary. The ordinary owned model contains no protobuf field
  IDs, StringTable IDs, block offsets or compression state. `PbfDocument`
  combines known HeaderBlock semantics, an `OwnedDataset`, and explicit raw
  preservation state. Semantic rewrite and exact-source reproduction are
  separate contracts.
- `readPbfDocument` and `PbfWriter` are the M4 durable PBF boundaries
  exported by `osm`. Semantic writing is fail-closed when raw preservation
  detects unrepresented source content or when required HeaderBlock feature
  declarations are missing. `writeOriginalSource` is explicitly distinct
  from semantic writing and reproduces only the captured source bytes.
- `comparePbfSemantics` reports the first structured semantic difference;
  the boolean `samePbfSemantics` helper remains available when diagnostics
  are not needed. M4 qualification uses the structured comparator plus an
  independent libosmium differential check.
- `osm.io.pbf.reader` is the supported direct-import module for the ordered
  consumer-facing PBF reader boundary exported by `osm`. The curated root also
  exports `PbfParallelReader` / `PbfParallelReadOptions`; their implementation
  module `osm.io.pbf.parallel_reader` is supported for the same summary-only
  API.
- `osm.xml` is the supported high-level ordinary OSM XML facade.
  It exports document-envelope metadata plus `OsmXmlReader`,
  `readOsmXmlDocument`, and `OsmXmlWriter` with their status/options types.
  The facade deliberately does not expose dxml parser/writer entities.
  `ByteSource` and `ByteSink` remain transport-d concepts rather than an
  osm-d-specific stream hierarchy.
- `osm.osmchange` is the supported high-level osmChange facade.
  It reuses `OwnedChangeSequence` and exports streaming/materializing reader
  and writer boundaries without exposing XML parser entities. Source entry
  order and explicit delete `if-unused` policy are semantic contracts.
- Other `osm.io.pbf.*` modules remain an evolving codec-development surface.
  Their documented decoding APIs may be used directly during pre-1.0
  development, but their module organization and callable signatures are not
  part of the high-level reader compatibility promise.
- `osm.wire.*` and `osm.util.*` are implementation-oriented modules. They are
  technically importable because D source modules are visible to consumers, but
  no source-compatibility promise is made for direct external use.

`package` visibility is not treated as a security, trust, or validated-state
provenance boundary. Construction-controlled invariants must rely on actual
representation/construction control rather than on a caller being outside a D
package namespace.

Before a stable API freeze, this classification must be reviewed against real
consumers. Stable direct imports, callable parameter names, template
instantiability, and representative named-argument forms must then be protected
by external-consumer compile tests across the supported compiler matrix.

The element-specific foreach boundaries have additional executable lifetime
checks. External `@safe` consumer compilation verifies normal Node, Way, and
Relation foreach use. DIP1000 compile-negative tests verify that iterables
borrowing stack-local input bytes cannot escape and that pointers to
callback-scoped `NodeView`, `WayView`, or `RelationView` values cannot
escape their foreach bodies. A complete traversal has the same whole-file
validation scope as `PbfReader.read`; an explicit early foreach exit is an
intentional partial traversal and leaves the unvisited suffix unvalidated.

## Public API surface

During pre-1.0 development, the package root `osm` remains intentionally small;
it does not re-export every technically importable implementation module.

Consumer-facing code should use documented high-level decoders, borrowed views,
ranges, status types, and format-independent contracts. Borrowed ranges reached
from `PbfReader` callbacks must remain iterable from external `scope ref`
`@safe` consumers; Fast CI compiles normal tags, DenseNodes tags, semantic
Way nodes, and Relation members through that boundary. Normal and DenseNodes
tag ranges both return the same semantic `TagView`; PBF StringTable IDs are
retained only inside codec ranges for validation and internal diagnostics.
The direct PBF representation remains available inside `package(osm)` for
codec tests and benchmarks, but ordinary external reader consumers see only the
semantic element surface: Node coordinates through `location`, metadata through
`metadata`, Way references through `nodes`, and no direct raw payload/offset
provenance fields. The external consumer compile probe protects this visibility
boundary.

Low-level validation
summaries and validate/prevalidated-build entry points are implementation
details when they exist only to carry proof from one internal decoding pass to
another. Such declarations use `package(osm)` where cross-module production use
requires visibility and are not part of the supported public API.

This distinction is correctness-relevant: callers must not be able to supply a
freely fabricated validation summary through the ordinary supported API and
thereby suppress data that is present in the encoded input.

D `package` protection is an organizational/API boundary, not a security or
provenance boundary. A separate source module can deliberately declare itself
inside the same package namespace. Library correctness therefore does not treat
`package(osm)` as protection against hostile code; it prevents ordinary external
imports from depending on unsupported validation internals.

## Parallel reader safety boundary

`PbfParallelReader.readSummary` is intentionally a small `@trusted` boundary.
The complete input remains alive for the call, queued jobs borrow immutable
Blob slices from it, the queue has fixed capacity, each worker owns one
`PbfReaderWorkspace`, and every worker is joined before return. No semantic
element view crosses a worker boundary.

The parallel API publishes only value-type summary/status results. Ordered
borrowed consumer callbacks remain the responsibility of `PbfReader.read` and
the element-specific foreach adapters. ADR 0017 deliberately closes Phase 3
without a generic ordered parallel borrowed-view API; future parallel decoded
element publication requires an explicit owned destination/store or a new
lifetime/backpressure contract.

## Build profiles

During early development keep correctness and performance work separable:

```bash
dub build
dub test
```

A benchmark profile will later record the exact LDC flags used for published
numbers. Optimization flags must not silently disable checks that belong to the
production integrity contract.

## Attributes

General direction:

- `@safe` by default;
- `@nogc` for wire/PBF hot paths where practical;
- `nothrow` for primitive decode helpers where error return values are used;
- `pure` only where semantically useful rather than as a blanket goal;
- `@trusted` only around reviewed code that establishes a safe contract over a
  small `@system` implementation;
- raw pointer arithmetic stays isolated in the wire/memory boundary.

## Ddoc/DDox documentation

Documentation is written together with the code, not as a cleanup pass. Every
public module starts with a Ddoc module comment immediately before the `module`
declaration. Module documentation includes at least:

- a concise purpose and contract;
- `Authors:`;
- `Date:` (the original module creation date, ISO `YYYY-MM-DD`);
- `Copyright:`;
- `License:`.

Every public type, enum, field whose meaning is not self-evident, and callable
API is documented. Callable APIs use Ddoc/DDox sections where applicable:

- `Params:` for all parameters;
- `Returns:` for non-`void` return contracts;
- `Throws:` only for exceptions that are part of the API contract;
- `See_Also:` for materially related public APIs;
- `Notes:` or `Safety:` when lifetime, ownership, `@trusted`, or other integrity
  constraints would otherwise be easy to miss.

Hot-path code is not exempt from documentation. In particular, borrowed
lifetimes, ownership, cursor advancement on failure, integer-overflow behavior,
and fail-closed decisions must be explicit in Ddoc. Git remains the source of
truth for change history; `Date:` is not manually bumped on every edit.

## Performance work

Do not optimize from intuition alone. For performance-sensitive changes:

1. state the expected bottleneck;
2. add or select a benchmark that isolates it;
3. record the baseline;
4. inspect generated code/profiles when necessary;
5. make the change;
6. rerun correctness, malformed-input and benchmark suites.

A microbenchmark improvement that worsens the end-to-end city workload is not
a project improvement.

## External byte-resource I/O

`osm-d` owns PBF/OSM interpretation and serialization, not filesystem, HTTP,
range, stream, retry, cache or scheduler policy. The workspace package
`transport-d` is the canonical byte-resource transport layer for those tasks;
see ADR 0019.

`transport-d` v0.1.1 is tagged and registry-resolvable. M5 therefore uses
`transport-d ~>0.1.1` as the byte-resource boundary for streaming XML, and
the external XML consumer compile probe resolves it through DUB. Future
source/sink adapters use the same contract rather than creating an
`osm-d`-specific I/O hierarchy.

## Dependencies

Dependencies are evaluated against:

- data-integrity implications;
- maintenance and format-conformance quality;
- `@safe`/`@nogc` compatibility where relevant;
- binary/runtime cost;
- benchmark evidence;
- whether the functionality is sufficiently generic to deserve a separate
  reusable D library instead.

Mir/`ndslice` is a candidate for compact-store numerical work, not a required
PBF parser dependency.

## Shared d-geospatial-workspace context

Repo-root project documents are specific to the standalone OSM library. The
repository and DUB package were still named `d-osm` at that checkpoint. The
coordinated reorganization on 2026-09-18 renamed both to `osm-d`.

Shared `d-geospatial-workspace` context is kept in `.workspace/` only.
`tools/link-workspace-docs.sh` is restricted to managing that directory.
Library-specific documentation must not modify shared workspace design
documents merely to record a local development checkpoint.
