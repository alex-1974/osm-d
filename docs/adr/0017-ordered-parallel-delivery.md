# ADR 0017: Phase 3 does not expose ordered parallel borrowed element delivery

- Status: Accepted
- Date: 2026-11-03
- Related: #48, #64

## Context

The production PBF reader now has two deliberately different execution modes:

- `PbfReader.read` and the `foreach` adapters provide ordered,
  consumer-visible borrowed semantic views on one reader thread;
- `PbfParallelReader.readSummary` performs bounded block-parallel validation
  and decoding, but publishes only owned summary/status values.

A worker reuses its `PbfReaderWorkspace` across blocks. Semantic views may
borrow the worker's decompression buffer and StringTable storage and therefore
cannot be placed in a reorder queue and consumed later without extending or
transferring ownership.

Phase 3 has no demonstrated consumer that requires generic ordered parallel
borrowed callbacks. Adding such an API now would force one of three costs:
materializing elements, transferring block ownership through a reorder queue,
or blocking worker reuse behind a consumer barrier.

## Decision

Phase 3 is complete without a generic ordered parallel element-delivery API.

Ordered element delivery remains provided by the serial direct-sink and
`foreach` paths. The parallel reader remains summary/status only.

The first planned consumer-visible use of parallel decoded elements is deferred
to the owned destination work in the compact-store milestone. Issue #64 will
evaluate direct PBF-to-store construction, where workers can construct durable
owned state rather than exporting worker-borrowed views.

If a future consumer needs a generic ordered parallel callback API independently
of the store, that is a new API/design decision. It must define lifetime,
backpressure, ordering, failure visibility, and memory bounds explicitly and be
qualified against the existing direct sink.

## Rejected alternatives for M3

### Queue borrowed semantic views

Rejected. The queued views would outlive reusable worker backing storage.

### Materialize every element into the merge queue

Rejected. It adds allocation/copy cost to solve a consumer requirement that has
not been demonstrated and would weaken the current borrowed hot-path design.

### Hold each worker buffer until ordered consumption

Rejected for M3. A consumer barrier can preserve lifetime, but it couples worker
progress and memory occupancy to consumer speed and needs its own throughput and
backpressure contract.

## Consequences

- there is no hidden ordered-merge stage in the current parallel reader;
- no borrowed semantic view crosses a worker-lifetime boundary;
- Phase 3 can close without speculative ownership machinery;
- direct construction into an owned model/store remains possible later;
- a future ordered parallel API cannot be inferred from the current
  `PbfParallelReader` contract.


## Resolution in M6 / #64 — 2026-11-04

#64 evaluated the deferred owned-destination boundary. ADR 0024 selects a
public direct `readPbfStore` path using the serial `PbfReader` and one reusable
workspace. It avoids the materialized object graph and builds the final compact
store and indexes in one single-writer pass.

No parallel owned-staging/merge API was added: the Bremen direct path already
measured 2.29x faster than materialized construction with a 1.070x peak/final
RSS ratio. A parallel store-construction API therefore remains future work only
if a representative consumer workload demonstrates a material bottleneck.
