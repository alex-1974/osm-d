# Contributing

## Priorities

Changes are evaluated in this order:

1. data integrity and conformance;
2. correctness and testability;
3. performance and bounded resource use;
4. API convenience.

A speedup that weakens integrity guarantees is not an acceptable optimization.

## Development workflow

Before changing a core invariant, wire format interpretation, ownership model
or public API boundary, update or add an ADR.

Run at least:

```bash
dub build
dub test
```

Performance-sensitive changes must include or reference an appropriate
benchmark. Parser-format changes must include conformance or regression tests.

## Code expectations

- `@safe` by default.
- `@system` only in narrowly scoped, documented low-level code.
- Prefer `@nogc` in benchmark-critical decode paths.
- Checked arithmetic for untrusted encoded values.
- No hidden normalization or repair of source data.
- Avoid heap ownership in borrowed view APIs.
- Avoid abstraction in the inner loop unless generated code and benchmarks show
  that it is free enough.

## Tests

Test categories live under:

- `tests/unit/`
- `tests/roundtrip/`
- `tests/regression/`
- `tests/malformed/`
- `tests/compatibility/`

Every data-loss bug requires a permanent regression fixture when licensing and
size permit.
