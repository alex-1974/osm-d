# ADR 0007: Performance and scalability are tested project contracts

- Status: Accepted
- Date: 2026-09-12

## Context

The first major application is an OSM editor, where complete city datasets must
be processed interactively enough to be practical. Performance cannot be
recovered cheaply if the data model begins with pervasive heap allocation,
pointer chasing and forced materialization.

## Decision

Performance is designed and continuously measured from the start.

- libosmium-class throughput is the initial production target for equivalent
  PBF scan work;
- benchmarks include single-thread and multicore scaling;
- integrity checks remain enabled in production benchmarks;
- the core decode loop aims for `@nogc` and zero-copy borrowed data;
- worker-local arenas and bounded queues are architectural primitives;
- LDC is the reference release-performance compiler;
- PGO, LTO, SIMD and Mir/`ndslice` are applied only when measurement justifies
  them;
- city-store construction has a separate benchmark from pure parsing.

## Consequences

Benchmark code and immutable test datasets are first-class project assets.
Performance claims require reproducible methodology. A faster implementation
that weakens integrity or format conformance is rejected.
