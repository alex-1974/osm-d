# ADR 0013: DenseNodes tags use validated borrowed ranges

- Status: Accepted
- Date: 2026-09-12

## Context

OSMPBF `DenseNodes.keys_vals` stores tags for all dense nodes in one logical
`int32` stream. Non-zero entries alternate key and value StringTable IDs, and
zero terminates one node. The field is packable, so valid protobuf may split it
across multiple packed segments, use unpacked occurrences, or merge repeated
`DenseNodes` submessages. An entirely empty stream means all dense nodes are
tagless.

The d-osm integrity contract forbids silently dropping malformed tags or
normalizing their order. The streaming architecture also must not allocate a
`Tag[]` or copy StringTable bytes for each node.

## Decision

`keys_vals` is handled in two stages:

1. Before any dense node reaches a sink, the complete logical stream is
   preflighted. Every non-zero entry must fit the positive signed-int32 domain,
   resolve to a non-zero StringTable entry, occur in a key/value pair, and—when
   the stream is non-empty—exactly one zero delimiter must exist per dense node.
2. A `DenseTagNodeCursor` then advances the same logical stream node by node and
   returns a `DenseTagRange`. The range is a copyable borrowed cursor over the
   original protobuf bytes and StringTable index. It preserves tag order and
   resolves key/value bytes lazily without string copies or tag-array
   materialization.

A completely empty logical `keys_vals` stream is treated as the schema-defined
all-tagless representation and therefore does not require synthetic delimiter
values.

The cursor accepts packed and unpacked wire forms and concatenates multiple
segments/messages in protobuf order. String bytes remain opaque byte slices;
UTF-8 policy is deliberately not folded into this hotpath.

## Consequences

- Malformed delimiter structure or StringTable references are rejected before
  the first node is emitted.
- Tag order and raw StringTable bytes are preserved exactly.
- Per-node tag access is allocation-free and compatible with worker-local block
  lifetimes.
- Iterating a returned range reparses only that node's logical protobuf values;
  this small cost is preferred to materializing per-tag descriptors before
  benchmarking demonstrates a need for another representation.
- Duplicate OSM tag keys are preserved here and remain a semantic validation
  concern above the wire-format decoder.
