# ADR 0011: PrimitiveBlock first-pass layout and indexed StringTable

- Status: Accepted
- Date: 2026-09-12

## Context

`PrimitiveBlock` is the performance-critical inner container of OSMPBF data. A
naive generated-protobuf representation would materialize messages, repeated
arrays, and strings before entity decoding. That conflicts with osm-d's goals
of city-scale streaming, bounded memory use, zero-copy views, and explicit
control over hot-path allocation.

At the same time, protobuf permits field reordering, unknown fields, duplicate
singular scalar fields, and repeated occurrences of a singular message field.
The required `stringtable` field therefore cannot safely be modeled as one
assumed contiguous canonical segment. Multiple StringTable message occurrences
merge, and their repeated `s` fields form one logical ordered table.

DenseNodes, ways, relations, roles, keys, values, and usernames repeatedly
reference StringTable entries by numeric ID. Rescanning the table for each
lookup would be unacceptable, while allocating a `string[]` would copy data and
add per-entry GC pressure.

## Decision

`osm-d` uses a two-pass, caller-buffered PrimitiveBlock preparation path:

1. `decodePrimitiveBlockLayout` performs one allocation-free top-level scan. It
   applies protobuf last-one-wins semantics to scalar metadata, counts borrowed
   PrimitiveGroup occurrences, structurally validates every StringTable
   occurrence, validates the required empty string at merged index zero, and
   counts the merged StringTable entries.
2. PrimitiveGroups remain opaque borrowed protobuf payloads at this stage and
   are exposed through an allocation-free range in original wire order.
3. `buildStringTableView` receives caller-owned `StringRef[]` storage, intended
   to come from the future per-worker BlockArena. It rescans only StringTable
   occurrences and stores compact offset/length pairs into the original
   PrimitiveBlock bytes.
4. `StringTableView` performs O(1) indexed lookup without copying string bytes.
   String bytes remain raw `bytes`; UTF-8 validation/semantic policy is not
   conflated with wire/layout decoding.
5. The complete PrimitiveBlock bytes remain authoritative so unknown fields and
   non-canonical field ordering are not silently erased by this preparation
   layer.

## Consequences

- No generic protobuf object graph is created for PrimitiveBlock preparation.
- No D GC allocation is required in the block layout or StringTable indexing
  path.
- The common later path can allocate one compact StringRef array from a
  worker-local arena and then perform constant-time string-ID lookup.
- Legal field ordering and repeated StringTable message occurrences are handled
  without a canonical-layout assumption.
- PrimitiveGroup semantics remain a separate next-stage concern, keeping the
  first vertical slice small and independently testable.
- StringTable indexing intentionally performs a second narrow scan; this trades
  a cheap sequential pass for predictable memory and avoids retaining a dynamic
  list of StringTable segments in the first-pass layout.
