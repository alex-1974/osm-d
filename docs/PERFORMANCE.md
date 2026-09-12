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
6. Worker-local scratch arenas avoid allocator contention.
7. Queues are bounded to provide backpressure and a predictable memory ceiling.
8. Per-element global locking or atomic counters are forbidden in the normal hot path.
9. Statistics are worker-local and reduced later.
10. Public range abstractions stop at the hot-path boundary unless measurement proves they compile away.

## PBF pipeline

```text
framing -> bounded jobs -> parallel decompress/decode -> optional ordered merge -> consumer
```

Blocks receive monotonically increasing sequence numbers. Workers may finish
out of order. APIs that promise input order reassemble output by sequence.

## Arena policy

Each worker owns a reusable block arena. Typical temporary allocations include
StringTable indices, unusual protobuf segment lists and other block-scoped
metadata. Resetting an arena is O(1).

The arena is not a substitute for the long-lived dataset store.

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
- LTO and PGO only after baseline profiling;
- Mir/`ndslice` for columnar numerical work only when benchmarks justify it.

## Compiler policy

Correctness is tested across supported D compilers where practical. Performance
numbers are produced with a documented LDC release configuration.

Compiler flags, CPU model, storage, thread count, OS and dataset hashes belong
in every published benchmark record.

## Memory targets

Streaming decode must not scale resident memory linearly with input size.
Peak memory should be approximately bounded by:

```text
input buffers
+ N worker decompression buffers
+ N worker arenas
+ bounded queue contents
+ current consumer state
```

Materializing a compact editable store is a separate benchmark with its own
memory target.
