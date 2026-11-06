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


## OSM topology boundary

Dataset/reference validation and topology traversal are separate layers.

`osm.validate` answers whether typed identities/references satisfy a complete
or intentionally partial dataset contract. `osm.topology` navigates those
references without changing that validity decision.

Direct topology resolution is ordered and lazy:

- `OsmStore` resolves through its authoritative typed primary indexes and
  reports stable handles;
- `OwnedDataset` uses an explicit consumer-built `OwnedDatasetIndex` rather
  than acquiring a hidden permanent index.

Recursive Relation child closure preserves member occurrence order and expands
Way members to ordered Node-reference occurrences. Relation identities are
expanded once per traversal so graph cycles terminate while the cyclic edge
remains visible.

Parent closure is distinct-element traversal. The compact store reuses its
maintained reverse indexes; OwnedDataset uses reverse edges built as part of
its explicit topology index.

Traversal work is bounded through caller-visible depth/visit/Relation limits and
a reusable workspace. Missing references remain explicit resolution states.
No topology API performs network fetch, geometry construction or silent repair.

Complete-object resolution and OSM area/multipolygon assembly are layered above
this graph API in M16; generic geometry/geodesy/spatial indexing remain outside
osm-d.



## Store architecture

The parser remains streaming. The future editor store solves a separate random
access problem. A compact store may use structure-of-arrays layouts for nodes,
ways, relations and tag ranges. `mir.ndslice` may be used where benchmarks show
a benefit for columnar numerical operations, but it is not a parser
prerequisite.


## Complete-object and geometry boundary

M16 layers complete OSM projections above `osm.topology` without turning
osm-d into a Euclidean geometry library.

The default complete-object representation remains OSM-native:

- exact `LocationView` latitude/longitude nanodegrees;
- ordered Way Node references and Relation members;
- explicit resolved/incomplete/invalid reference state;
- borrowed projections over `OsmStore` or `OwnedDataset` plus its explicit
  `OwnedDatasetIndex`.

No direct `geo-d` dependency is introduced merely to reuse geometry types.
Consumers enter Euclidean geometry space explicitly by mapping longitude to x
and latitude to y. Generic geometry algorithms remain in `geo-d`; projection
and geodesy remain in `geodesy-d`; spatial indexing remains in
`spatial-index-d`.

M16 may expose exact OSM-native location bounds and identity-based closed-Way
detection. A syntactically closed Way is not thereby a valid polygon or area.

Complete-object traversal does not deep-copy an object graph and does not
silently allocate coordinate arrays. Data-dependent OSM ring/multipolygon
assembly may use explicit owning result/workspace storage because assembly
creates new structure; generic polygon computation remains outside osm-d.

Focused facades are:

- `osm.complete` for resolved complete-object projections;
- `osm.area` for OSM area/multipolygon assembly.

Neither is part of the curated package root by default.



## OSM area assembly boundary

`osm.area` sits above `osm.complete` and owns the OSM-specific transformation
from Way/member graphs into ring sequences.

Its connectivity primitive is exact OSM Node identity. It may reverse the
traversal of a source Way without mutating source and it preserves source
Way/member provenance in the assembled path.

Current multipolygon assembly accepts explicit `outer` / `inner` Way
members. It does not guess missing roles or reinterpret nested Relations.

The result is owning because ring assembly creates new data-dependent path
structure. Missing positive references remain partial; multiply-connectable
endpoints remain ambiguous; complete-data dangling chains are invalid.

The assembler deliberately stops before generic geometry. Ring simplicity,
intersection, containment, orientation, area, clipping and projection remain
outside osm-d. This preserves the ADR 0030 no-implicit-`geo-d` dependency
boundary.



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

In released v0.3.x, HTTP method selection, endpoint URLs, authentication,
retry/backoff and changeset creation/closing remained outside osm-d. ADR 0032
supersedes that architectural boundary for post-v0.3 development: osm-d now
owns OSM method/path/media/status semantics and the changeset protocol
operations, while transport-d still owns generic network execution. Secret
storage, OAuth login/account selection, retry/backoff and editor workflow remain
outside osm-d.



## Changeset semantic/XML boundary

Changesets are first-class OSM domain objects but are not Node/Way/Relation
elements. The focused `osm.changeset` facade therefore owns a separate
`OwnedChangeset` model with explicit presence for optional server fields.

Server state and editable request state are deliberately distinct:

```text
Changeset read/query XML
    -> OwnedChangeset
       id/open/timestamps/user/bounds/counts/tags/discussion

Changeset create/update intent
    -> ChangesetTagRequest
       tags only
    -> Changeset XML request body
```

This prevents server-managed identity, bounds, timestamps, ownership and
statistics from appearing writable. Update tags are a complete replacement
set, matching the Editing API contract.

The reader accepts the same model for one read response and Changeset query/list
responses, retains exact nanodegree bounds and distinguishes discussion absent
from discussion present-but-empty. Resource limits bound Changeset, child,
comment and comment-text materialization.

The codec layer has no HTTP behavior. ADR 0032's protocol client composes these
values/codecs with the future generic transport exchange.

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

The caller still selects the target server and owns caching/refresh cadence.
Under ADR 0032 the post-v0.3 protocol layer owns the OSM capability endpoint,
HTTP method and OSM-specific readonly/offline interpretation. Generic network
execution remains in transport-d, while credential storage and OAuth/account
policy remain outside osm-d.


## Editing API protocol boundary

ADR 0032 defines the post-v0.3 Editing API architecture.

```text
credentials-d -- scoped secret ----+
                                    |
                                    v
application policy ---> osm-d OSM protocol layer ---> transport-d HTTP exchange
                        | method/path/media/status     | TLS/socket/curl
                        | changeset operations         | generic limits/errors
                        | existing XML codecs          | secret-safe provenance
                        v                              v
                    OSM semantic values              network
```

The consumer explicitly selects the API base URL. osm-d appends OSM
operation-relative paths and owns the method/media/status semantics. It never
silently chooses the production OpenStreetMap server for write-capable work.

The intended focused facade is `osm.api`, centered on an
`EditingApiClient`-style domain API. The concrete transport adapter is blocked
on the generic bounded HTTP exchange requested in `transport-d#3`; osm-d must
not bypass that dependency by importing a concrete HTTP backend.

Authorization material is request-scoped and must not be retained or copied
into ordinary diagnostics/provenance. credentials-d may supply protected
secrets, while OAuth2/PKCE login, token refresh, account selection and retry
policy remain outside osm-d.

The protocol client is synchronous at this seam and accepts an injected generic
exchange so deterministic fake/mock transport can qualify every operation
without live network access. Async execution remains caller/executor policy.
