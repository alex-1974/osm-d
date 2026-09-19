# Architecture

## Purpose

`osm-d` separates four concerns that are often conflated in OSM libraries:

1. decoding bytes;
2. preserving what was actually present in the source;
3. validating OSM semantics;
4. presenting convenient application-level objects.

This separation is essential for both loss avoidance and speed.

## Layering

```text
public API
    |
    +-- model/          owned, durable OSM values
    +-- view/           borrowed zero-copy views
    +-- raw/            loss-aware source representation
    +-- validation/     explicit validation stages
    +-- io/
    |    +-- pbf/
    |    +-- xml/
    |    `-- change/
    +-- store/          compact random-access storage
    +-- wire/           protobuf wire primitives, OSM-agnostic
    +-- memory/         arenas, buffers, ownership
    `-- util/           checked arithmetic, endian helpers
```

Dependencies point upward only. `wire` knows nothing about OSM. `memory` knows
nothing about PBF. PBF DenseNode decoding knows nothing about the editor.

## PBF hot path

```text
file / stream
    |
    v
framing reader
    | BlockJob(sequence, kind, owned compressed buffer)
    v
bounded work queue
    |
    +---------------- worker N ----------------+
    | decompress into reusable worker buffer   |
    | scan protobuf -> block layout             |
    | index StringTable in worker arena         |
    | decode PrimitiveGroups                    |
    | decode varints / zigzag / deltas          |
    | structural validation                     |
    | emit NodeView / WayView / RelationView    |
    +-------------------------------------------+
    |
    v
ordered merge when required
    |
    v
range boundary / sink / compact store
```

### Inner boundary

The innermost decoder is intentionally simple and push-based:

```d
DecodeStatus decodeBlock(Sink)(
    scope const(ubyte)[] block,
    ref BlockArena arena,
    ref Sink sink
) @nogc;
```

This allows static dispatch and inlining for counting, validation, range
bridging and direct store construction.

### Public boundary

The public API may expose D ranges:

```d
auto reader = PbfReader("city.osm.pbf");
foreach (scope element; reader.elements) {
    // borrowed concrete view satisfying the ElementView contract
}
```

Ranges do not dictate the inner varint implementation.

`ElementView` denotes the format-independent structural contract defined by
`osm.view.element`, not one mandatory cross-codec storage type. A reader may
therefore expose a codec-specific borrowed value whose `type` and `id` satisfy
that contract. Generic semantic consumers can constrain on the contract while
the codec retains its own cursor and backing-state representation.

## Borrowed and owned data

A borrowed view may reference the current decompressed block, StringTable or
worker arena. It must not outlive that block.

Long-lived data is created explicitly:

```text
borrowed view satisfying ElementView contract -> explicit copy -> owned model
borrowed view satisfying ElementView contract -> direct append -> compact store
```

There is no implicit materialization of every parsed element.

## Safety zones

| Area | Intended attributes |
| --- | --- |
| `wire/cursor.d` | tiny audited `@system` core, `@nogc`, `nothrow` where possible |
| `wire/*` | `@safe` where possible, `@nogc`, benchmark-critical |
| `io/pbf/dense.d` | `@nogc`, benchmark-critical |
| `view/*` | `@safe`, borrowed, no ownership ambiguity |
| `model/*` | `@safe`, owned values |
| `store/compact/*` | allocation-controlled, cache-oriented |

`@system` code must not spread through the library. Unsafe code is isolated,
audited and fuzzed.

## Validation stages

Validation is layered:

```text
wire validity
  -> format structural validity
  -> OSM element validity
  -> dataset/reference validity
  -> uploadability
```

A dataset can therefore be decodable without being valid OSM, valid OSM
without being referentially complete, or editable without being uploadable.
These states must never be conflated.

## Store architecture

The parser remains streaming. The future editor store solves a separate random
access problem. A compact store may use structure-of-arrays layouts for nodes,
ways, relations and tag ranges. `mir.ndslice` may be used where benchmarks show
a benefit for columnar numerical operations, but it is not a parser
prerequisite.
