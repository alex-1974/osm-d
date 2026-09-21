# Development Policy

## Compilers

DMD is suitable for fast edit/build/test cycles. LDC is the reference compiler
for release-performance measurements because the production hot paths are
intended to benefit from LLVM optimization.

During pre-1.0 development, the currently supported and tested compiler matrix is:

- DMD 2.111.0;
- LDC 1.41.0 using DMD frontend 2.111.0.

No compatibility guarantee is currently made for older D frontends. A historical
minimum frontend will be fixed only when there is evidence that supporting it is
useful and the corresponding compiler matrix can be tested deliberately. Newer
compiler releases are added to the supported matrix only after validation.

The canonical local correctness checks are:

```bash
dub test --compiler=dmd --force
dub test --compiler=ldc2 --force
dub build --compiler=ldc2 --build=release --force
tests/run-dip1000-negative.sh
```

GitHub Actions runs the supported DMD/LDC matrix for pushes to `main` and pull
requests. Each compiler job runs its unit tests and DIP1000 lifetime-negative
checks; the LDC job additionally performs the release build.

## Public module surface during pre-1.0

D module visibility and package support are separate concerns. A source module
being directly importable does not by itself make every declaration in that
module part of a compatibility promise.

The current pre-1.0 surface is classified as follows:

- `osm` is the curated package root. It intentionally does not re-export the
  evolving implementation surface yet.
- `osm.view.element` is a supported semantic direct-import API. Its
  `ElementType`, `OsmId`, and structural `isElementView` contract form the
  format-independent borrowed element identity boundary described by ADR 0016.
- `osm.io.pbf.*` is an evolving codec-development surface. Its documented
  decoding APIs may be used directly during pre-1.0 development, but their
  module organization and callable signatures are not frozen until the public
  PBF reader/range boundary is established.
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

## Public API surface

During pre-1.0 development, the package root `osm` remains intentionally small;
it does not re-export every technically importable implementation module.

Consumer-facing code should use documented high-level decoders, borrowed views,
ranges, status types, and format-independent contracts. Low-level validation
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
