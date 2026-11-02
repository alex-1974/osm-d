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
```

GitHub Actions separates checks by branch trust level.

For pushes to `develop` and pull requests targeting `develop`, Fast CI runs the
supported DMD 2.111.0 and LDC 1.41.0 matrix. Each compiler job runs unit tests,
an external-consumer compile probe through the curated package root, DIP1000
lifetime-negative checks, and a release build.

For pull requests targeting `main`, pushes to `main`, and release/hotfix
branches, the Release Gate runs the full six-compiler qualification matrix and
additionally builds the parser decode-count benchmark as a consumer-facing
parser smoke test. This deliberately keeps expensive cross-generation
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
  `PbfNodeIterable`, `PbfReadSummary`, `PbfReadStatus`, `PbfReadError`)
  plus the
  format-independent semantic node/identity/location/metadata/tag/member/way-node
  vocabulary (`NodeView`, `OsmId`, `ElementType`, `LocationView`,
  `MetadataView`, `TagView`, `RelationMemberView`, `WayNodeView`).
  `NodeView` is the one concrete callback/foreach value type used for regular
  Node and DenseNodes encoding. `PbfNodeIterable` is the node-only convenience
  adapter returned by `PbfReader.nodes`; it is an `opApply` foreach adapter,
  not a resumable Phobos InputRange. It does not re-export
  the evolving low-level
  PBF or wire implementation surface.
- `osm.view.element`, `osm.view.location`, `osm.view.metadata`,
  `osm.view.tag`, `osm.view.relation_member`, and `osm.view.way_node` are
  supported semantic direct-import APIs. The `ElementType`, `OsmId`,
  structural `isElementView` contract, `LocationView`, `MetadataView`,
  `TagView`, `RelationMemberView`, and `WayNodeView` form the current
  format-independent borrowed semantic boundary described by ADR 0016 and the
  consumer API design. The package-root `NodeView` is callback-scoped and
  deliberately non-copyable; semantic subviews and tag-range copies remain
  ordinary values.
- `osm.io.pbf.reader` is the supported direct-import module for the same
  consumer-facing PBF reader boundary exported by `osm`.
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

The node foreach boundary has additional executable lifetime checks. External
`@safe` consumer compilation verifies normal foreach use. DIP1000
compile-negative tests verify that an iterable borrowing stack-local input
bytes cannot escape and that a pointer to the callback-scoped `NodeView`
cannot escape the foreach body. A complete traversal has the same whole-file
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
