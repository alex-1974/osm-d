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
external DUB consumer probes, deterministic JOSM-/iD-compatible edit
interoperability fixtures, DIP1000 lifetime-negative checks, the deterministic
wire malformed-input seed corpus, PBF round-trip smoke tests, and release/
benchmark builds. The DMD baseline additionally generates osmChange output with
`osm-d` and requires Ubuntu's `osmium-tool`/libosmium to parse it successfully.

For pull requests targeting `main`, pushes to `main`, and release/hotfix
branches, the Release Gate runs the full six-compiler qualification matrix,
reruns the deterministic malformed-input, round-trip, and editor
interoperability gates, compiles the external consumers, and builds the parser
decode-count benchmark. The baseline DMD job also repeats the osmChange
`osmium-tool` interoperability check. This
keeps expensive cross-generation qualification out of ordinary `develop`
commits while requiring it before release promotion. `main` remains the
release line; normal development targets `develop`.

## Public module surface

The supported v0.2.x source contract is frozen in
`docs/API_STABILITY.md`. The deliberate v0.1 -> v0.2 migration is documented
in `docs/API_V0_2.md`.

Preferred v0.2 facades:

- `osm`: common OSM identity/semantic values, owned model, borrowed
  Node/Way/Relation views, one-shot/reusable PBF traversal and editable store;
- `osm.pbf`: PBF-specific document preservation, writer, parallel summary and
  PBF semantic-comparison facilities;
- `osm.store`: editable store facade;
- `osm.compare`: serialization-independent OSM/change semantic comparison;
- `osm.xml`: ordinary OSM XML;
- `osm.osmchange`: osmChange;
- `osm.validate`: upload-readiness validation.

Shared semantic leaves are `LocationView`, `MetadataView`, `TagView`,
`NodeRefView` and `RelationMemberView`. Store ranges keep their own
lifetime/invalidation machinery but return these same values.

`OsmHandle` remains the stable editor identity. Typed
`OsmStore.node/way/relation(OsmId, ...)` is the ordinary direct lookup path;
generic `find(ElementType, OsmId, OsmHandle)` remains available.

One-shot PBF consumers may call `readPbf`; repeated callers retain
`PbfReaderWorkspace` and use `PbfReader.read` so scratch allocations are
reused.

Other `osm.io.pbf.*`, `osm.wire.*`, `osm.util.*` and
`osm.store.compact.*` modules are implementation/development surfaces unless
explicitly listed in the release compatibility document.

`package` visibility is not a security or provenance mechanism. Invariants
rely on representation/construction control and executable tests.

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
without a generic ordered parallel borrowed-view API; ADR 0024 resolves the M6 owned-destination case with public single-writer
`readPbfStore`. A future parallel store-construction path still requires a
separate measured ownership/ordering/backpressure contract; M6 does not expose
one because the direct serial construction path already satisfies the city
throughput and peak-memory targets.

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
