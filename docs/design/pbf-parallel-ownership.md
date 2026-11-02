# Parallel PBF ownership and lifetime contract

**Status:** Phase-3 production-reader contract  
**Scope:** already-loaded whole-buffer PBF input

## Purpose

The first parallel reader must increase block-level throughput without weakening
osm-d's borrowed-view, validation, or allocation contracts. This document fixes
the ownership model before queue and worker implementation.

## Whole-buffer job ownership

`PbfReader` currently receives one caller-owned `const(ubyte)[]` containing
the complete encoded PBF. The input remains alive for the complete read call.

For this API a queued OSMData job therefore contains only value metadata and a
borrowed immutable Blob slice:

```text
ParallelBlockJob
    sequence
    file offset
    const(ubyte)[] serialized Blob  -> borrows whole input
```

The producer does **not** copy every compressed Blob into a new buffer merely to
transfer work to another thread. All workers are joined before the parallel
read returns, so no queued job can outlive the caller's input borrow.

A future streaming/file-descriptor reader may need owned or pooled compressed
buffers because its source bytes can be overwritten before a worker consumes
them. That is a different ownership policy and must not be imposed on the
whole-buffer API.

## Worker ownership

Each worker owns exactly one reusable `PbfReaderWorkspace` for its lifetime.

The workspace owns/grows:

- decompression bytes;
- StringTable reference storage;
- Way decode-plan storage.

No workspace is shared between workers. A worker reuses its capacity across
successive blocks instead of allocating scratch per element or per block after
capacity is sufficient.

A separate linear arena is not part of this first parallel implementation.
It is introduced only if allocation/peak-memory evidence shows a temporary
storage problem that the existing workspace cannot solve cleanly.

## Borrowed decoded data

Within one worker:

```text
job Blob slice
  -> BlobView
  -> BlobPayloadView
       raw: borrows job/input bytes
       compressed: borrows worker decompression buffer
  -> PrimitiveBlock / StringTable / semantic element views
```

All such views are block-scoped. The worker may reuse its decompression buffer
for the next job immediately after the current job has finished.

The first parallel API therefore emits no borrowed element views to an external
consumer. It performs complete validated block decoding into a no-op semantic
sink and returns only owned value summaries/status. This avoids either:

- concurrently invoking an arbitrary shared consumer handler;
- copying/materializing every element to extend its lifetime; or
- pretending worker-backed views survive queue advancement.

Ordered or consumer-visible element delivery is a later contract.

## Bounded queue and backpressure

The producer frames the caller's input sequentially and pushes OSMData jobs into
a fixed-capacity queue. When the queue is full, the producer waits until a
worker consumes a job.

Memory attributable to queued compressed work is therefore bounded by the queue
array itself; queued jobs only contain borrowed slices, not duplicate payload
storage.

No per-element mutex or atomic operation is permitted. Synchronization occurs
only at job/queue granularity.

## Header and framing responsibilities

File framing and the required OSMHeader contract remain serial:

1. framing assigns monotonically increasing file-block sequence numbers;
2. the leading OSMHeader Blob is decoded and feature-validated before worker
   OSMData processing begins;
3. duplicate headers, data-before-header, unknown block types, and malformed
   framing remain producer-side failures;
4. only OSMData Blob jobs enter the worker queue.

This keeps the file-level state machine deterministic.

## Failure semantics

Workers use isolated summaries for each block. A failed block contributes no
counts.

Because the initial parallel API has no external element callbacks, workers may
finish already-queued work even after another worker has found malformed input.
After all workers join, the reader selects the failure with the smallest file
block sequence across producer and worker failures.

This preserves deterministic earliest-block diagnostics without exposing
elements from a suffix that would have been unobservable after failure.
`PbfReadSummary` is published only on complete success.

## Result reduction

Each worker accumulates only value-type `PbfReadSummary` counters and its
earliest local failure. The caller thread reduces successful worker summaries
after every thread has joined.

There is no global per-element counter and no shared mutable sink.

## Future ordered element delivery

Ordered merge remains intentionally separate. Consumer-visible borrowed views
cannot simply be stored in a reorder queue because their payload/StringTable
backing belongs to a reusable worker workspace.

A future ordered design must explicitly choose a lifetime-preserving mechanism,
for example block ownership transfer, a consumer barrier before worker-buffer
reuse, or direct construction of an owned destination/store. It must not
silently materialize every OSM element.
