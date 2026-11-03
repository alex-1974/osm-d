# ADR 0005: PBF decoding uses bounded block-parallel workers

- Status: Accepted
- Date: 2026-09-12
- Updated: 2026-11-03 by ADR 0017

## Context

OSM PBF is naturally block-structured. Primitive blocks can be decompressed and
decoded independently, while large inputs demand bounded memory and effective
use of multicore systems.

## Decision

The production parallel reader uses a staged pipeline:

```text
serial framing + HeaderBlock validation
 -> bounded OSMData job queue
 -> worker-local decompression
 -> protobuf layout scan
 -> StringTable index in the worker workspace
 -> PrimitiveGroup decode + structural validation
 -> worker-local summary/status reduction
 -> caller-thread reduction after all workers join
```

Each worker owns one reusable `PbfReaderWorkspace`. No separate block arena is
part of the current production implementation; additional temporary-storage
machinery is introduced only when measured allocation or peak-memory evidence
requires it.

Queued jobs borrow immutable serialized Blob slices from the caller-owned
whole-buffer input. Queues are bounded. Blocks carry sequence numbers so
parallel failure reduction can still report the earliest failing file block
deterministically.

The parallel API does not expose worker-borrowed semantic views. Ordered
consumer-visible element traversal remains on the serial direct-sink and
`foreach` paths. ADR 0017 defers any parallel owned-element delivery to an
owned destination/store design rather than adding a speculative ordered merge
of borrowed views.

The single-thread implementation remains a first-class path and benchmark.

## Consequences

Parallel scaling is available without global per-element synchronization or
hidden per-element materialization. Worker scratch capacity is reused across
blocks. The current whole-buffer API still keeps the encoded input resident, so
process RSS is not independent of total file size even though queued work and
decode scratch are bounded.

Any future generic ordered parallel element API requires a separate ownership,
backpressure and performance contract.
