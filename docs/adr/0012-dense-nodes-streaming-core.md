# ADR 0012: DenseNodes streaming core

- Status: Accepted
- Date: 2026-09-12

## Context

DenseNodes is expected to be the dominant node representation in normal OSM
PBF data. The decoder therefore needs a hot path that avoids per-node
allocation while preserving protobuf compatibility and exact integer
semantics.

The protobuf schema marks the `id`, `lat`, and `lon` columns as packed repeated
`sint64`, but protobuf permits packable repeated scalar fields to be encoded in
packed form, unpacked form, or multiple segments. Multiple serialized
DenseNodes occurrences also merge as one singular message under protobuf
semantics.

A streaming sink is desirable for future direct decode into validation and
compact-store consumers. At the same time, malformed input must not reveal a
late coordinate overflow only after nodes have already been emitted.

## Decision

1. Decode PrimitiveGroup and DenseNodes structure in an allocation-free first
   pass.
2. Accept packed and unpacked `id`, `lat`, and `lon` values, including multiple
   segments and repeated DenseNodes message occurrences.
3. During validation, ZigZag-decode and checked-accumulate every delta. Record
   the minimum and maximum cumulative latitude and longitude values.
4. Reject unequal ID/latitude/longitude column lengths before semantic decode.
5. Before the first sink call, use the validated cumulative extrema to prove
   that `offset + granularity * value` is representable for the entire latitude
   and longitude streams.
6. Decode the validated columns again into a statically dispatched `@nogc`
   sink, emitting exact nanodegree coordinates as signed 64-bit integers.
7. Keep DenseInfo and `keys_vals` out of this first semantic slice. They are
   structurally validated/countable now and will receive dedicated decoding in
   later changes.

## Consequences

The design uses one validation pass and one emission pass over dense columns.
This costs more raw varint work than a single-pass best-effort parser, but
ensures that column mismatch, delta overflow, and coordinate overflow are known
before output is committed. The second pass has no allocation and maps directly
to the future worker/sink architecture.

Later benchmarking may justify a specialized canonical-packed fast path, but
it must retain the same semantics and continue accepting legal unpacked and
multi-segment protobuf representations.
