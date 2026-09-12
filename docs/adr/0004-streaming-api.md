# ADR 0004: Ranges at boundaries, push-based decoding in the hot path

- Status: Accepted
- Date: 2026-09-12

## Context

D ranges are idiomatic, lazy and composable, but forcing a deep stack of range
adaptors through every varint, ZigZag and delta operation risks making the
critical decode loop harder to reason about and benchmark.

## Decision

The innermost format decoder is push-based and parameterized by a statically
dispatched sink. Public streaming APIs expose D range-compatible iteration.

Conceptually:

```text
bytes -> imperative @nogc decoder -> sink -> range boundary -> user pipeline
```

The compiler may inline sink operations into the decoder. A direct sink API is
also available for high-throughput operations such as compact-store building.

## Consequences

Users retain idiomatic D iteration while the core decoder remains simple,
allocation-controlled and measurable. Range abstractions may move inward only
when benchmarks and generated-code inspection show no meaningful penalty.
