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
    |    +-- osmchange/
    |    `-- upload/
    +-- store/          compact random-access storage
    +-- wire/           protobuf wire primitives, OSM-agnostic
    +-- memory/         arenas, buffers, ownership
    `-- util/           checked arithmetic, endian helpers
```

Dependencies point upward only. `wire` knows nothing about OSM. `memory` knows
nothing about PBF. PBF DenseNode decoding knows nothing about the editor.

## PBF hot path

```text
encoded PBF bytes
    |
    +-- whole-buffer slice
    |      -> framing borrows immutable Blob slices
    |
    `-- transport-d ByteSource
           -> bounded prefix/Header/Blob reads
           -> reusable current-block buffers
    |
    v
Blob decode / bounded decompression
    |
    v
PrimitiveBlock + StringTable + PrimitiveGroup decode
    |
    v
push-decoded borrowed Node/Way/Relation views
    |
    +-- statically dispatched consumer sink
    +-- opApply foreach / where! convenience
    `-- direct compact OsmStore build

The serial reader owns ordered consumer-visible borrowing. The separate
parallel-summary reader may borrow immutable whole-buffer Blob slices because
it publishes summaries rather than worker-borrowed semantic views.
```

### Inner boundary

The innermost decoder is intentionally simple and push-based:

```d
DecodeStatus decodeBlock(Sink)(
    scope const(ubyte)[] block,
    ref WorkerWorkspace workspace,
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
reader workspace. It must not outlive that block. For ByteSource reads, the
serialized current-block buffers are likewise reusable scratch and are replaced
only after all synchronous callbacks for that block return. Whole-buffer
parallel jobs may borrow immutable Blob slices directly from the caller's
complete input because every worker is joined before the read returns. Worker decompression
and decode scratch remains worker-owned and reusable.

The parallel summary reader intentionally exports no worker-borrowed semantic
views. ADR 0017 keeps ordered consumer-visible borrowed traversal on the serial
reader path and defers parallel decoded-element publication to a future owned
destination/store contract.

Long-lived data is created explicitly:

```text
borrowed view satisfying ElementView contract -> explicit copy -> owned model
borrowed view satisfying ElementView contract -> direct append -> compact store
```

There is no implicit materialization of every parsed element.

## Safety zones

| Area | Intended attributes |
| --- | --- |
| `wire/cursor.d` | `@safe`, `@nogc`, `nothrow`; slice-backed cursor with no raw-pointer core |
| `wire/*` | `@safe` where possible, `@nogc`, benchmark-critical |
| `io/pbf/dense.d` | `@nogc`, benchmark-critical |
| `view/*` | `@safe`, borrowed, no ownership ambiguity |
| `model/*` | `@safe`, owned values |
| `store/compact/*` | allocation-controlled, cache-oriented |

`@system` or `@trusted` code must not spread through the library. Unsafe or
trusted transitions are isolated and audited. Notable production
`@trusted` boundaries include:

- the bounded zlib C-API bridge in `io/pbf/decompress.d`;
- dxml orchestration in the OSM XML, osmChange and upload-result readers.
  dxml entities/ranges remain inside the synchronous parse call; public
  callbacks receive owned semantic values and no parser borrow escapes;
- the narrow direct-PBF-store adapter in `store/pbf.d`, which bridges the
  older generic reader signature to a scoped public input. Its safety argument
  is that `PbfReader.read` is synchronous and `StoreSink` copies every
  accepted semantic value into store-owned storage before the callback returns.
  The external DIP1000 store-consumer probe exercises this public boundary.

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

The public dataset/reference stage makes completeness explicit:

- `complete`: every typed reference resolves to a local live identity;
- `partial`: missing positive/server targets are permitted, while unresolved
  negative/local references remain invalid.

A retained store tombstone is known local deletion state rather than an
external omission and therefore never satisfies a live reference. Relation
cycles are reference-valid when every typed target exists; recursive traversal
must handle cycles separately.


## Store architecture

The parser remains streaming. The future editor store solves a separate random
access problem. A compact store may use structure-of-arrays layouts for nodes,
ways, relations and tag ranges. `mir.ndslice` may be used where benchmarks show
a benefit for columnar numerical operations, but it is not a parser
prerequisite.


## Editing API upload-response boundary

osm-d owns the OSM semantics and wire formats around a diff upload, but not the
network session that transports them:

```text
OsmStore
   -> OwnedChangeSequence
   -> osmChange XML
   -> application/network boundary
   -> diffResult XML
   -> UploadResult
   -> OsmStore.applyUploadResult
```

`osm.io.upload` parses the successful API 0.6 `diffResult` response through
the same transport-d/dxml boundary used by ordinary OSM XML and osmChange.
Entry order and raw old/new ID/version fields are preserved. The parser never
infers create/modify/delete from response shape; semantic interpretation uses
the exact uploaded request entry through `UploadResultEntry.effectFor`.

HTTP method selection, endpoint URLs, authentication, retry/backoff,
changeset creation/closing and editor workflow remain application/service
concerns. This prevents osm-d from becoming an OSM account/network client while
still keeping OSM-specific response parsing reusable.


## Editing API capability discovery boundary

Target-server upload limits are policy, not format constants. osm-d discovers
the relevant policy through a narrow projection:

```text
capabilities XML
    -> EditingApiCapabilities
    -> CapabilityProfile
    -> validateUploadChanges
```

`osm.io.capabilities` reuses the same transport-d/dxml boundary as the other
XML codecs. It strictly validates the projected API version and
Way/Relation/Changeset upload limits while boundedly skipping unrelated
capability families such as map/Notes/GPX query policy and imagery rules.

This asymmetry is deliberate: the parser does not claim to be a lossless
capabilities-document model. It is a named editing/upload projection whose
forward-compatible skip policy is part of its contract.

Endpoint selection, HTTP caching, authentication, refresh cadence and behavior
when the API reports readonly/offline remain consumer/service policy.
