# ADR 0005: PBF decoding uses bounded block-parallel workers

- Status: Accepted
- Date: 2026-09-12

## Context

OSM PBF is naturally block-structured. Primitive blocks can be decompressed and
decoded independently, while large inputs demand bounded memory and effective
use of multicore systems.

## Decision

The production reader uses a staged pipeline:

```text
framing
 -> bounded BlockJob queue
 -> worker-local decompression
 -> protobuf layout scan
 -> StringTable view/index
 -> PrimitiveGroup decode
 -> structural validation
 -> borrowed element views / sink
 -> ordered merge only when requested
```

Each worker owns reusable decompression storage and a block arena. Queues are
bounded. Blocks carry sequence numbers so decoding may execute out of order
without forcing observable reordering on APIs that promise input order.

The single-thread implementation remains a first-class path and benchmark.

## Consequences

Peak parser memory is largely independent of total file size. Parallel scaling
is available without global per-element synchronization. Ordering has an
explicit cost rather than being accidentally lost.
