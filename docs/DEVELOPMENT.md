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
```

CI does not currently define this matrix; until CI is introduced, these local
checks are the authoritative compiler verification for repository changes.

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
