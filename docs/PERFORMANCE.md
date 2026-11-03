# Performance and Scalability Contract

## Principle

Performance is architectural, not a cleanup phase.

A city-scale OSM dataset must be streamable and processable with bounded
memory and without mandatory object-per-element allocation. Integrity checks
remain enabled in production-performance benchmarks.

## Reference level

The production PBF reader should aim for the same performance class as strong
native OSM readers, with libosmium as the primary baseline. Faster specialized
PBF implementations are useful stretch references.

Performance claims are made only from reproducible benchmarks on identical
input and hardware.

## Hot-path rules

1. No mandatory GC allocation per OSM element.
2. `@nogc` for the core wire and PBF decode loops where practical.
3. Borrow source bytes and StringTable strings rather than copying them.
4. Decode DenseNodes directly from packed/delta streams.
5. Use checked integer arithmetic; integrity checks are not benchmark options.
6. Worker-local reusable workspaces keep decode scratch isolated and reusable; a separate arena requires measured justification.
7. Queues are bounded to provide backpressure and a predictable memory ceiling.
8. Per-element global locking or atomic counters are forbidden in the normal hot path.
9. Statistics are worker-local and reduced later.
10. Public range abstractions stop at the hot-path boundary unless measurement proves they compile away.

## PBF pipeline

```text
framing -> bounded jobs -> parallel decompress/decode -> summary/status reduction

ordered borrowed traversal -> serial PbfReader
future parallel decoded elements -> explicit owned destination/store contract
```

Blocks receive monotonically increasing sequence numbers. Workers may finish
out of order. The current parallel API publishes only aggregate summary/status
after all workers join and reduces failures to the earliest file-block
sequence. ADR 0017 deliberately keeps ordered borrowed element traversal on the
serial reader path; a future parallel owned-destination path is tracked by
#64.

## Scratch-storage policy

The single-thread reader reuses one caller-owned `PbfReaderWorkspace`.
Its decompression buffer, StringTable index storage, and Way decode-plan
storage may grow when a larger block requires more capacity. The inner
validated element decoders remain `@nogc`; workspace growth is the deliberate
allocation boundary.

The parallel summary reader applies the same rule per worker: each worker owns
one reusable `PbfReaderWorkspace` and processes multiple queued OSMData jobs
with that scratch. Whole-buffer jobs borrow immutable Blob slices instead of
copying compressed payloads. The queue is fixed-capacity, so producer memory
cannot grow with the number of file blocks.

A separate worker-local linear arena is added only if measured temporary
allocation pressure requires one. Scratch storage is not a substitute for the
long-lived dataset store.

## Fast and slow paths

Common canonical PBF encodings receive a direct fast path. Legal unusual
protobuf encodings, including segmented or unpacked representations of
packable repeated scalar fields, remain supported through a correct slow path.

A fast path may improve the common case; it may never redefine validity.

## D-specific strategy

The project should exploit D where it produces measurable benefits:

- slices as cheap borrowed views;
- templates/static dispatch for sinks and specialized decode paths;
- `scope` to constrain borrowed values;
- `@nogc` for hot paths;
- `@safe` by default with very small audited `@trusted`/`@system` islands;
- value types over heap objects in decoding;
- LDC/LLVM for release-performance builds;
- LTO and PGO only when a stable consumer workload and measured bottleneck justify them;
- Mir/`ndslice` for columnar numerical work only when benchmarks justify it.

## Compiler policy

Correctness is tested across supported D compilers where practical. Performance
numbers are produced with a documented LDC release configuration.

Compiler flags, CPU model, storage, thread count, OS and dataset hashes belong
in every published benchmark record.

## M3 allocation and PGO decision — 2026-11-03

M3 does not introduce a separate worker-local linear arena or PGO.

The reusable workspace already meets the intended steady-state allocation
contract on the qualified workloads:

- Bremen: the first complete serial read allocated 4,694,192 D-GC bytes while
  scratch capacity grew; the second and third reads allocated **0 D-GC bytes**
  and caused **0 collections**;
- Austria (808,820,532-byte pinned input): the first complete serial read
  allocated 11,067,568 D-GC bytes with **0 collections**; the second allocated
  **0 D-GC bytes** and caused **0 collections**;
- the bounded parallel Bremen qualification showed useful 2- and 4-worker
  scaling without evidence of allocator contention that a new arena must solve.

A linear arena remains an available implementation technique if a later owned
model/store or new temporary decode structure introduces measured allocation
pressure. It is not a missing Phase-3 component.

PGO is likewise deferred. The current evidence does not isolate a stable
consumer-visible residual bottleneck for which PGO is the justified next
mechanism. If later release-scale measurements establish such a gap, PGO may be
qualified as an optimization against the same semantic workload. It is not an
M3 completion requirement.

## Memory targets

The current public PBF APIs receive an already-loaded whole input buffer, so
process RSS necessarily includes that input and therefore grows with input
size. The **additional reader working set** should remain approximately bounded
by:

```text
caller-owned input
+ N reusable worker workspaces
  (decompression + StringTable refs + Way plans)
+ fixed-capacity queue metadata
+ current consumer/summary state
```

Queued whole-buffer jobs borrow Blob slices and do not duplicate compressed
payload bytes. Materializing a compact editable store is a separate benchmark
with its own memory target.
