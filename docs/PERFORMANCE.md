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


## M6 compact-store targets

ADR 0021 and `docs/design/compact-store-contract.md` define the M6 decision
workloads. The primary layout decision uses the pinned `bremen-260901`
city/editor-scale dataset.

The production candidate is compared with a straightforward reference store
that provides the **same primary and parent indexes**. The first architecture
targets are:

- final incremental RSS no more than 75% of that equivalent reference store;
- Bremen final incremental RSS at or below 512 MiB excluding the identical
  caller-owned PBF input buffer, with 384 MiB as a stretch target;
- direct PBF construction peak incremental RSS no more than 1.5x final store
  incremental RSS, again excluding the identical input buffer.

These are engineering decision budgets, not public guarantees for arbitrary OSM
datasets. Missing a target triggers investigation; it does not justify data
loss, disabled integrity checks or benchmark-only representations.


## M6 production parent-index qualification — 2026-11-04

ADR 0023 replaces the #62 benchmark-only reverse index on the compact side
with the production incremental indexes. On pinned Bremen with LDC 1.41.0
release/allAtOnce:

- production parent-index logical bytes: **73,415,112** versus **78,577,608**
  for the static packed reference;
- Node -> Way: 64.680 ms p50 for 250,000 queries versus 31.746 ms static;
- typed element -> Relation: 3.461 ms p50 for 100,000 queries versus 2.952 ms;
- 10,000 representative edits including reverse-index maintenance: 29.210 ms;
- static-reference full parent rebuild after the same edits: 396.032 ms;
- production store parent rebuild after edits: **none**;
- final compact RSS: **351,324 KiB (343.090 MiB)**;
- total logical compact bytes: **308,976,077**.

The linked mutable index deliberately trades some read-only Node-parent
locality for incremental edit coherence. The static packed reference is faster
for pure parent lookup but cannot remain coherent after edits without a
whole-store rebuild. The production result retains the <=75% reference-RSS,
<=512 MiB, and <=384 MiB M6 memory gates.


## M6 direct PBF-to-store qualification — 2026-11-04

ADR 0024 selects direct single-writer construction through `readPbfStore`.
The public path feeds validated borrowed `PbfReader` semantics directly into
the compact store and production indexes; it allocates no worker queue and no
block-local durable staging store.

Pinned Monaco and Liechtenstein complete semantic checksums matched the
materialized reference. Bremen additionally matched all store semantic,
primary/parent lookup, edit, revert and ID-remap checks.

Bremen, LDC 1.41.0 release/allAtOnce:

- direct PBF -> fully indexed store: **2,268.417 ms**;
- materialized PBF -> `PbfDocument`: **4,139.849 ms**;
- materialized `OwnedDataset` -> store: **1,045.288 ms**;
- combined materialized path: **5,185.137 ms = 2.285795x direct**;
- final incremental RSS: **357,908 KiB (349.520 MiB)**;
- peak incremental RSS: **383,104 KiB**;
- peak/final RSS: **1.070398x**, target <=1.5x: **PASS**;
- logical owned store bytes: **308,976,077**;
- parent-index bytes: **73,415,112**.

The <=512 MiB city and <=384 MiB stretch budgets remain PASS.

A parallel owned-destination staging/merge path is not selected for M6.
`OsmStore` is intentionally single-writer, and the direct serial path already
cuts the measured materialized load time by more than half while remaining far
inside the peak-memory budget. Parallel construction may be reconsidered only
with a measured consumer bottleneck and an explicit bounded ownership/ordering
contract.
