# Development Policy

## Compilers

DMD is suitable for fast edit/build/test cycles. LDC is the reference compiler
for release-performance measurements because the production hot paths are
intended to benefit from LLVM optimization.

Exact minimum supported compiler versions will be fixed only after the first
working PBF vertical slice and CI matrix exist.

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

## Shared d-geospatial workspace

Repo-root project documents are specific to `d-osm`. Shared workspace context
is linked into `.workspace/` only. `tools/link-workspace-docs.sh` is restricted
to managing that directory.
