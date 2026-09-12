# OSM Specification and Real-World Compatibility Matrix

This document maps normative OSM and Protocol Buffers requirements to observed
real-world implementation behavior and to explicit `d-osm` design decisions.
It is a design input and test plan, not merely background documentation.

Verification date: **2026-09-12**.

## Evidence hierarchy

When sources disagree, use this order:

1. canonical schema or normative protocol rule;
2. current OSM Editing API behavior/documentation;
3. documented real-world format behavior;
4. multiple established implementations;
5. `d-osm` behavior.

No reference implementation defines correctness by itself.

## Status vocabulary

- **MUST** — required for the first production-capable implementation.
- **SHOULD** — strong compatibility requirement; deviation needs an ADR.
- **RAW** — accepted/preserved by the loss-aware raw layer but not necessarily
  accepted by the validated OSM model.
- **REJECT** — decoding/conversion/upload must fail closed.
- **OPEN** — requires additional evidence before implementation is frozen.

## Source keys

Primary sources are listed in full in `REFERENCES.md`.

- **N1** — OSM API v0.6
- **N2** — OSM Elements / data model
- **N3** — OSM XML
- **N4** — OsmChange
- **N5** — canonical `OSM-binary/osmformat.proto`
- **N6** — canonical `OSM-binary/fileformat.proto`
- **N7** — OSM PBF format documentation
- **N8** — Protocol Buffers binary encoding
- **R1** — JOSM `AbstractReader`
- **R2** — JOSM `OsmWriter`
- **R3** — iD architecture
- **R4** — iD `osmChangeset`
- **R5** — iD OSM service/capability handling
- **R6** — libosmium / protozero
- **R7** — libosmium issue #389 and v2.23.0 fix

---

## 1. Identity, IDs and versioning

| Topic | Normative / observed rule | Reference behavior | `d-osm` decision | Required tests |
| --- | --- | --- | --- | --- |
| Element identity | Node, Way and Relation IDs live in separate namespaces. Type + ID identifies an OSM element. | iD prefixes IDs internally by type. | **MUST:** identity type is `(ElementType, OsmId)`. Never use numeric ID alone as a global key. | Same numeric ID for node, way and relation. |
| ID width | Current API documents element/member IDs as implementation-dependent signed 64-bit integers. PBF fields are 64-bit integer types. | JOSM uses Java `long`; iD treats server IDs as opaque strings. | **MUST:** `alias OsmId = long`; checked parsing; no narrowing. Treat numeric magnitude as semantically opaque. | `long.min`, `long.max`, large positive IDs, invalid overflow. |
| Negative IDs | Editors/change files use negative IDs for local/placeholder objects. | JOSM external IDs <= 0 identify local/server-unknown primitives; iD assigns negative local IDs. | **MUST:** preserve signed IDs. Negative values are valid in editor/change contexts, not automatically invalid data. | Negative node/way/relation IDs and references. |
| ID zero | OSM API-created objects receive positive server IDs; common editors do not serialize zero as an established primitive ID. | JOSM writer rejects primitive unique ID 0. | **SHOULD:** validated persisted/server objects reject zero. Raw layer can represent source zero for diagnostics. | Raw zero ID; validation rejection. |
| Version | API uses element versions for optimistic locking. Version starts at 1 and normally increments, but clients must use the server-returned version rather than assume `+1`. | Editors retain baseline versions. | **MUST:** version is explicit optional metadata; upload requires authoritative current baseline version for modify/delete. | Missing version in extracts vs upload; 409 conflict simulation. |
| New local objects | New objects may lack a server version until created. | JOSM/iD distinguish new local objects. | **MUST:** do not encode absence using sentinel version 0 in the core model. Use explicit presence/state. | Local new object without server metadata. |

Sources: N1, N3, N4, N5, R1, R3.

---

## 2. Tags

| Topic | Normative / observed rule | Reference behavior | `d-osm` decision | Required tests |
| --- | --- | --- | --- | --- |
| Key/value length | OSM tag keys and values are Unicode strings up to 255 characters. | API rejects invalid element data. | **MUST:** validated OSM model enforces current API/data-model limits when target policy is API-compatible. | 255 / 256 character boundaries. |
| Duplicate keys | An OSM element cannot validly contain two tags with the same key; API 0.6 rejects duplicates. | JOSM/iD semantic models use map-like tag storage. | **RAW:** raw parser preserves duplicate tag entries and source order. **REJECT:** conversion to validated OSM model fails on duplicate keys. Never keep-first, keep-last or merge implicitly. | Duplicate identical/different values; XML and PBF. |
| Tag order | OSM semantics do not define tag order as element meaning. | JOSM sorts tags by key when writing. | **MUST:** validated model may offer keyed lookup but should retain stable input order where inexpensive. Lossless/raw roundtrip preserves order. Never claim lexical identity from semantic roundtrip. | Reordered semantic equivalence; raw-order preservation. |
| Unknown tagging vocabulary | OSM tags are an open folksonomy. | Editors expose unknown tags. | **MUST:** never filter tags by a schema/preset vocabulary. | Unknown keys/values survive roundtrip. |
| PBF key/value arrays | PBF Node/Way/Relation encode keys and values as parallel arrays of StringTable indices. | Established PBF readers assume pairing. | **MUST:** lengths must match; every index must be valid; mismatch is structural error. | unequal arrays, out-of-range indices. |

Sources: N2, N5, API duplicate-tag errors, R2.

---

## 3. Ways and relations: order, multiplicity and references

| Topic | Normative / observed rule | Reference behavior | `d-osm` decision | Required tests |
| --- | --- | --- | --- | --- |
| Way node order | A way is an ordered sequence of node references. | All major editors preserve order; JOSM writes in stored order. | **MUST:** preserve exact ref order and duplicates. Generic codec must not simplify or deduplicate. | repeated refs; closed way; roundtrip order. |
| Relation member order | Relation members are ordered; order is meaningful for several relation types. | iD/JOSM retain member arrays in model. | **MUST:** preserve exact member order. | route/restriction-style ordered members. |
| Duplicate relation members | Depending on relation type, the same element may legitimately occur multiple times. | iD tagging schema can explicitly allow duplicate members for relation types. | **MUST:** parser/core never deduplicates relation members. Semantic validators may add relation-type-specific diagnostics separately. | same `(type,id,role)` repeated; differing roles. |
| Member type | Relation member type is node/way/relation and is part of the reference identity. | All major implementations model it explicitly. | **MUST:** never infer member type from ID. | same ID used by all three types. |
| Missing positive referenced object | Extracts/API bbox results may contain structurally complete ways/relations whose referenced objects are not all loaded. | JOSM creates incomplete positive-ID placeholders. | **MUST:** preserve the reference and represent dependency absence explicitly. It is not parser corruption and not sufficient reason to drop the member/ref. | partial bbox-style dataset. |
| Missing negative/local referenced object | A local reference should resolve within the local edit/change state. | JOSM treats missing negative referenced nodes/members as data-integrity errors. | **REJECT** for editable/uploadable validated state. Raw files may still be inspected. | unresolved `-1` node/member. |
| Deleted referenced primitive | A loaded object can be deleted/history-visible false. | JOSM logs/filters some deleted references during dataset preparation. | **MUST NOT copy JOSM filtering into raw/core codec.** Preserve the serialized reference; higher layers decide whether an operation is valid. | deleted member/ref retained in raw semantic decode. |

Sources: N1, N2, N5, R1, R2, R3.

---

## 4. Partial datasets and completeness

`d-osm` must distinguish different kinds of completeness. They are not a single
boolean.

| State | Meaning | Decision |
| --- | --- | --- |
| structurally complete element | All data serialized *inside* the element was decoded. | Required before semantic serialization. |
| dependency-resolved element | All referenced nodes/members are present in the loaded dataset. | Optional; depends on consumer. |
| response/document complete | Parser reached a valid end and no API error marker/truncation invalidated the document. | Required before committing an API load. |
| referentially complete dataset | All references resolve within the dataset. | Not guaranteed for extracts/bbox responses. |
| uploadable object | Complete authoritative object + required baseline/version/change state is present. | Stronger than decodable/valid. |

The OSM bbox API explicitly does not recursively provide complete relation
closure. A relation in a valid API result may reference members absent from the
result. Therefore an unresolved positive reference must never be silently
removed or treated as proof that the containing serialized relation is
malformed.

Sources: N1, R1.

---

## 5. Coordinates

| Topic | Normative / observed rule | Reference behavior | `d-osm` decision | Required tests |
| --- | --- | --- | --- | --- |
| PBF representation | Coordinates are signed integer values with per-PrimitiveBlock granularity and offsets. Formula is integer nanodegree based. | libosmium uses fixed-point integer locations internally. | **MUST:** authoritative PBF decode uses checked integer arithmetic, never `double`. | non-default granularity/offset; overflow edges. |
| Default granularity | Default is 100 nanodegrees (1e-7 degree). | Common planet/extract PBFs use this. | **MUST:** defaults come from schema semantics, not producer assumptions. | omitted granularity/offset. |
| Canonical OSM coordinate model | Server/API coordinates are effectively represented at OSM fixed decimal precision; PBF can formally express arbitrary granularity/offset combinations. | Other tools commonly normalize to 1e-7 degree. | **MUST NOT ROUND SILENTLY.** Raw/exact coordinate survives. Conversion to a canonical 1e-7 OSM coordinate succeeds only if lossless. | finer-than-1e-7 exact coordinate remains raw/noncanonical. |
| Floating point API | Geometry consumers commonly want doubles. | Editors use floating-point geometry. | `double` is derived convenience only, never roundtrip source of truth. | integer -> double does not mutate stored exact value. |
| Geographic bounds | API rejects nodes outside the world. | Editors validate coordinates. | Validated API-target model checks latitude/longitude bounds; raw codec reports but does not repair. | ±90/±180 boundaries and outside values. |

Sources: N1, N5, R6.

---

## 6. Metadata and history

| Topic | Normative / observed rule | `d-osm` decision | Required tests |
| --- | --- | --- | --- |
| Metadata omission | PBF `Info` may be absent; extracts can omit metadata; XML variants may omit historical attributes. | Every metadata field uses explicit presence. No sentinel substitution in public model. | omitmeta PBF/XML. |
| `visible` | PBF `visible=false` represents deletion/history state. When writers use it, `HistoricalInformation` is required. | History/current state is explicit. Writer enforces feature/header dependency. | deleted historical object; feature missing. |
| DenseInfo | Several DenseInfo numeric fields are delta coded. | Separate checked accumulators; validate all populated column counts against DenseNodes count according to schema semantics. | truncated one metadata column; delta overflow. |
| timestamp | PBF timestamp is scaled by `date_granularity`. | Checked integer representation first; time object conversion later. | non-default date granularity, overflow. |
| replication metadata | HeaderBlock can carry replication timestamp, sequence number and base URL. | Preserve as document/header metadata; never attach to an arbitrary element. | header roundtrip. |

Sources: N3, N5.

---

## 7. Protobuf wire compatibility

This section is critical. OSM PBF uses a fixed protobuf schema, but the wire
format permits more encodings than typical OSM producers emit.

| Topic | Protocol Buffers rule | `d-osm` decision | Required tests |
| --- | --- | --- | --- |
| Field order | Serialized fields may occur in any order. | **MUST:** never depend on canonical producer ordering. | shuffled fields for every PBF message type. |
| Unknown fields | Wire type allows parsers to skip unknown fields. | Read-only semantic decode may skip. For promised format roundtrip, preserve opaque field bytes or mark rewrite unsafe. | unknown varint/fixed/LEN field. |
| Repeated order | Order of values of a repeated field is preserved. | Concatenate repeated occurrences in wire order. | interleaved repeated fields. |
| Packed vs unpacked | Parsers must accept packable repeated scalar fields in both packed and expanded/unpacked encodings, regardless of schema declaration. | **MUST:** both encodings accepted. | protobuf-net single-value unpacked regression. |
| Multiple packed segments | Multiple packed records for one field are valid; payloads concatenate. | **MUST:** segmented cursor/slow path produces one logical repeated sequence. | 2+ packed segments interleaved with other fields. |
| Singular duplicates | Binary protobuf parsers use last-one-wins for scalar/string singular fields; embedded messages merge. | Raw layer preserves wire occurrences when format preservation is requested. Semantic protobuf view follows protobuf rules, while strict PBF validation may additionally flag noncanonical/schema-invalid duplication. | duplicate singular scalar/message field. |
| Malformed varint | Varints are bounded by target width; truncated/overflow encodings are malformed. | **REJECT:** compact `@nogc` error with byte offset; no wraparound. | 10-byte/11-byte edge cases, unterminated varint. |
| Length-delimited bounds | Length must fit remaining buffer and configured resource limits. | **REJECT:** checked arithmetic before pointer movement/allocation. | huge length, integer wrap, truncated LEN. |

The libosmium #389 regression is mandatory corpus data: libosmium 2.20 failed
to read an unpacked single-element repeated field generated by protobuf-net,
while JOSM accepted it. libosmium v2.23.0 later fixed this. `d-osm` must pass
this case from the first PBF-capable release.

Sources: N8, R7.

---

## 8. PBF file framing and compression

| Topic | Normative / canonical rule | `d-osm` decision | Required tests |
| --- | --- | --- | --- |
| File framing | 4-byte network-order BlobHeader length, then BlobHeader, then `datasize` bytes of Blob. | Dedicated framing layer; no OSM semantic parsing here. | truncated prefix/header/blob; endian test. |
| Header ordering | `OSMHeader` must precede the first `OSMData` block. | Strict validated PBF reader rejects missing/late required header state. Raw block scanner may inspect damaged files. | missing header; data before header. |
| Unknown FileBlock type | PBF documentation says unknown block types can be skipped. | Read-only reader skips safely. Lossless rewrite preserves opaque complete block bytes or refuses format-roundtrip claim. | custom block before/between data blocks. |
| BlobHeader size | Should be <32 KiB, must be <64 KiB. | **REJECT** at >=64 KiB before allocation/read amplification. | 32/64 KiB boundaries. |
| Uncompressed Blob size | Should be <16 MiB, must be <32 MiB. | **REJECT** >=32 MiB uncompressed declaration/result. | decompression bomb / raw_size mismatch. |
| Compression | Readers/writers must support raw and zlib; LZMA/LZ4/Zstd are optional schema alternatives; bzip2 field is deprecated. | Initial production reader **MUST** support raw+zlib. Optional codecs are capability-gated. Never reinterpret unsupported compression. | each supported codec; multiple oneof values malformed. |
| Blob `raw_size` | Used for compressed uncompressed size. | Validate sign/range and actual decompressed size. | negative/incorrect raw_size. |

Sources: N6, N7.

---

## 9. PBF HeaderBlock features

| Topic | Rule | `d-osm` decision | Required tests |
| --- | --- | --- | --- |
| unknown required feature | Reader that does not understand a required feature must reject the file and report it. | **REJECT** with feature names. | synthetic `FutureFeature`. |
| unknown optional feature | May be ignored for interpretation. | Read-only semantic decode allowed. Format rewrite requires preservation or explicit loss acceptance. | opaque optional feature. |
| `OsmSchema-V0.6` | Defined required feature for OSM schema 0.6. | Validate supported schema contract. | missing/duplicate/unknown combinations. |
| `DenseNodes` | Indicates dense node encoding support/use. | Reader supports before accepting file that requires it. | dense feature + dense groups. |
| `HistoricalInformation` | Signals history data / visible semantics. | Header capability carried into element validation. | visible false with/without feature. |
| `LocationsOnWays` | Optional feature used when way lat/lon columns are present. | If locations are used, feature must be present and refs/lat/lon counts equal. | missing feature, unequal arrays. |

Sources: N5, N7.

---

## 10. PrimitiveBlock and StringTable

| Topic | Rule | `d-osm` decision | Required tests |
| --- | --- | --- | --- |
| Block independence | Each PrimitiveBlock is independently parsable and has its own StringTable and coordinate/timestamp parameters. | Natural unit for worker jobs, arena lifetime and parallel decode. | parallel blocks with different granularity/string tables. |
| StringTable index 0 | Reserved as blank delimiter and is always blank/unused. | Strict PBF validation verifies index 0 representation; Dense tag delimiter is integer 0. | nonempty index 0. |
| StringTable storage | Schema uses `bytes`, not protobuf `string`. | Byte validity and OSM text conversion are distinct stages. **OPEN:** exact invalid-UTF-8 preservation/writer policy requires dedicated evidence and ADR before final API. | invalid UTF-8 fixture held pending decision. |
| StringTable lookup | All tag keys/values, roles and usernames reference table indices. | Bounds check every lookup; no unchecked producer trust. | index == count, huge index. |
| PrimitiveGroup type rule | Canonical schema comments state primitives in a group are the same type. | Validate rather than assume; raw protobuf scanner can expose malformed mixed groups for diagnostics. | mixed-type group. |

Sources: N5.

---

## 11. DenseNodes

| Topic | Rule | `d-osm` decision | Required tests |
| --- | --- | --- | --- |
| ID/lat/lon | Three repeated delta-coded signed integer columns represent nodes. | Direct cursor decode with independent checked accumulators. | negative deltas, overflow, empty columns. |
| Column cardinality | One logical ID/lat/lon value is needed per dense node. | **REJECT** inconsistent logical counts after concatenating packed/unpacked segments. | IDs shorter/longer than lat/lon. |
| `keys_vals` | Flat key/value StringTable IDs, with 0 delimiter per node; may be empty if all nodes are tagless. | Streaming tag cursor; do not allocate `Tag[]` per node. Validate pairs, delimiters and indices. | missing delimiter, odd pair, extra nodes. |
| DenseInfo | Optional columnar metadata; several fields delta coded. | Synchronized cursors; no object-per-node metadata allocation. | sparse/mismatched columns according to allowed schema presence. |
| Hot-path allocation | Not normative, but performance critical. | `decodeDenseNodes(Sink)` target is `@nogc`; worker-local arena only for exceptional/block-scoped supporting data. | allocation counter benchmark. |

Sources: N5, PERFORMANCE.md.

---

## 12. Ways in PBF

| Topic | Rule | `d-osm` decision | Required tests |
| --- | --- | --- | --- |
| refs | Delta-coded repeated signed IDs, order significant. | Borrowed lazy `WayRefRange`/cursor; exact order. | positive/negative deltas, repeated IDs. |
| LocationsOnWays | Optional lat/lon arrays are delta coded; if used refs/lat/lon counts must match and feature declared. | Validate all three conditions; no partial approximation. | every mismatch combination. |
| tags | parallel key/value StringTable indices. | Validate equal lengths/indices; preserve raw tag sequence. | malformed pair arrays. |

Sources: N5, N7.

---

## 13. Relations in PBF

| Topic | Rule | `d-osm` decision | Required tests |
| --- | --- | --- | --- |
| member columns | `roles_sid`, delta-coded `memids`, and `types` are parallel arrays. | **MUST:** equal logical counts; stream in exact order. | unequal columns, segmented fields. |
| member type enum | NODE/WAY/RELATION are defined values. | Unknown enum value preserved at raw wire level; validated OSM relation rejects unsupported member type. | enum 3+. |
| roles | role is referenced through StringTable. | Checked index; empty role is valid. | blank role, invalid sid. |
| duplicate members | Schema imposes no generic uniqueness. | Preserve duplicates. | duplicates with same/different roles. |

Sources: N2, N5.

---

## 14. OSM XML

OSM XML is a family of closely related interchange forms, not a byte-stable
canonical serialization.

| Topic | Observed/documented behavior | `d-osm` decision | Required tests |
| --- | --- | --- | --- |
| block order | Conventional/documented entity block order is nodes, ways, relations; blocks may be absent and IDs need not be sorted. | Reader does not require ID sorting. Writer may choose deterministic type order but must document semantic vs format roundtrip mode. | unsorted IDs; missing type blocks. |
| negative IDs | Negative IDs occur in editor files. | Preserve signed IDs. | JOSM-style local objects. |
| metadata presence | Metadata/user/version details vary between API, extracts, history and editor files. | Explicit optional metadata fields; no sentinels. | omitmeta/editor variants. |
| unknown attributes/elements | JOSM/Overpass and other producers have extensions/flavours. | Raw XML layer preserves supported unknown metadata/extension structures for loss-aware roundtrip, or marks rewrite unsafe. **Never convert unknown attributes into OSM tags implicitly.** | custom root/element attribute and child extension. |
| lexical XML identity | Whitespace, quote style, attribute order, entity spelling and comments are not OSM semantics. | First production contract is semantic/loss-aware roundtrip, **not byte-identical XML**. Exact lexical preservation is out of scope unless separately designed. | semantically equivalent XML. |

Sources: N3, R2.

---

## 15. OsmChange and upload construction

| Topic | Rule | Reference behavior | `d-osm` decision | Required tests |
| --- | --- | --- | --- | --- |
| actions | `create`, `modify`, `delete` act on whole elements, not individual tags. | iD emits the three groups. | **MUST:** change model contains whole-object states. | tag-only logical edit still serializes full object. |
| modify representation | API update requires the complete intended object; omitted tags/refs/members disappear. | iD entity serializers emit full state. | **MUST:** never serialize a partial object as modify. Baseline/current graph difference drives changes. | missing unchanged tag/ref would be detected pre-upload. |
| placeholder IDs | Negative local IDs are the safe interoperable placeholder convention; Rails substitution effectively requires negative refs for replacement. | iD/JOSM use negative local IDs. | **MUST:** generated create placeholders are negative and unique within upload scope. | create node -> way -> relation chain. |
| dependency order | Current API rejects forward references to placeholders. | iD sorts new relations by dependencies and orders create node->way->relation. | **MUST:** build dependency graph/topological order; detect cycles/unresolvable placeholder graphs before network call. | forward ref, nested relations, cycle. |
| modify order | iD emits node->way->relation. | Useful deterministic policy. | **SHOULD:** deterministic dependency-safe order where applicable; correctness does not rely on arbitrary source order. | stable serializer test. |
| delete order | iD emits relation->way->node and `if-unused=true`. | Mature editor policy. | API layer chooses an explicit deletion policy. Default should be conservative and documented; do not accidentally inject `if-unused`. | used object deletion with/without policy. |
| diff upload transaction | One diff upload request is transactional: all applied or none. A whole changeset spanning requests is not globally atomic. | Editors use diff upload. | **MUST:** transaction boundary represented as request, not changeset object. | simulated failure mid-diff => no local commit. |
| diffResult | Server maps uploaded IDs and returns new IDs/versions for successful create/modify results as applicable. | Editors update local graph from server response. | **MUST:** apply returned mapping/version; never assume version increment or server ID. | old->new placeholder mapping. |

Sources: N1, N4, R4.

---

## 16. OSM API response integrity

| Topic | Rule | `d-osm` decision | Required tests |
| --- | --- | --- | --- |
| HTTP 200 + internal `<error>`/error entry | API documentation explicitly says response can be syntactically correct but incomplete; editing applications MUST discard the whole response. | Network/API adapter stages results transactionally and commits only after document completion validation. | fixture with valid elements followed by error marker commits **zero** elements. |
| optimistic locking | Wrong current version yields 409 Conflict. | Baseline version retained; conflict surfaced, never automatically overwritten. | stale version fixture. |
| server response version | Client should use returned new version, not predict it. | Apply response as authority. | non-`+1` mocked version. |
| bbox closure | Map endpoint relation closure is deliberately nonrecursive. | Partiality explicit; unresolved positive refs allowed in dataset. | bbox-like fixture with relation missing children. |

Sources: N1.

---

## 17. API capabilities and limits

The current documentation shows example values such as 2000 way nodes, 32000
relation members and 10000 changeset elements, but explicitly states that
actual values may change.

| Topic | Rule | Reference behavior | `d-osm` decision | Required tests |
| --- | --- | --- | --- | --- |
| capability values | Query server capabilities; values are server/policy state, not format constants. | iD has defaults then updates at least way-node/changeset limits from API status. | **MUST:** API validators take a `CapabilityProfile`; no current server limit is hardcoded as normative model truth. | mocked capability changes. |
| offline validation | No server may be available. | Editors use defaults/fallbacks. | Separate *format validity* from *target-server uploadability*. Offline policy may carry explicit configured defaults. | same object valid format but invalid against smaller server cap. |

Sources: N1, R5.

---

## 18. Reference implementation lessons

### JOSM

Borrow:

- explicit incomplete positive-ID primitives;
- hard failure for unresolved local/negative references;
- mature distinction between parse and dataset preparation.

Do **not** treat as lossless behavior:

- writer sorts object IDs and tag keys;
- writer skips incomplete primitives;
- dataset preparation may omit deleted references from reconstructed member/node lists.

Therefore JOSM is an editor-behavior reference, not a raw roundtrip oracle.

### iD

Borrow:

- immutable entity/baseline graph model;
- difference-based edit derivation;
- typed ID namespaces;
- dependency-aware OsmChange ordering;
- capability-derived API limits.

Do not copy browser-specific numeric/string/JSON representation choices into the
codec without independent justification.

### libosmium / protozero

Borrow:

- streaming/block-oriented architecture;
- compact buffers and borrowed object views;
- minimalist schema-specialized protobuf approach;
- fixed-point coordinate philosophy.

Do not treat libosmium as normative. Issue #389 demonstrates that a fast,
mature parser can still reject/lose a legal protobuf encoding. Differential
comparison must therefore always include the canonical wire rules.

---

## 19. `d-osm` integrity capabilities

The API should eventually expose these concepts independently rather than one
`valid` flag:

```text
decodable
formatValid
validOsm
referentiallyComplete
semanticallyRoundtrippable
formatRoundtrippable
uploadable
```

Examples:

- an extract relation with missing positive members can be `validOsm=true` and
  `referentiallyComplete=false`;
- a PBF with an unknown optional feature may be semantically decodable but
  `formatRoundtrippable=false` until that feature can be preserved;
- an object loaded without version metadata can be valid data but
  `uploadable=false` as a modification;
- an API response containing an internal error can contain individually valid
  elements while `documentComplete=false`; none may be committed.

---

## 20. Mandatory regression corpus before PBF reader milestone

The initial compatibility corpus must contain at least:

1. canonical raw PBF and zlib PBF;
2. non-default granularity and coordinate offsets;
3. DenseNodes with and without tags/metadata;
4. Ways with repeated node refs;
5. Relations with repeated members and blank roles;
6. packed repeated scalar fields split into multiple segments;
7. the unpacked-single-value repeated-field pattern from libosmium #389;
8. reordered protobuf fields;
9. unknown protobuf wire fields;
10. unknown optional PBF feature;
11. unknown required PBF feature;
12. custom/unknown FileBlock;
13. truncated/overflow varints;
14. out-of-range StringTable indices;
15. inconsistent parallel arrays;
16. BlobHeader and Blob size-boundary cases;
17. duplicate OSM tag keys;
18. partial dataset with unresolved positive references;
19. missing negative/local reference;
20. API-style HTTP-200 incomplete document fixture.

Every real data-loss bug discovered after this point adds a permanent fixture.

---

## 21. Open questions requiring separate decision/evidence

These remain deliberately unresolved rather than guessed:

1. **PBF StringTable invalid UTF-8:** exact distinction between wire-valid
   `bytes`, OSM text validity and lossless preservation policy.
2. **Unknown protobuf field rewrite:** preserve individual unknown wire fields
   versus preserve untouched encoded submessage/block as opaque bytes.
3. **XML extension preservation:** exact scope of unknown attributes/elements
   promised by `formatRoundtrippable`.
4. **Canonical validated tag container:** ordered `Tag[]` + index, small-vector
   representation, or another structure that preserves stable ordering without
   sacrificing lookup speed.
5. **Canonical coordinate conversion:** precise rule for accepting exact PBF
   coordinates into the normal OSM 1e-7 model without rounding.
6. **Delete policy:** default use of API `if-unused` belongs in the future API
   layer and must be explicit.

Each resolved item should update this matrix and, when architectural, gain an
ADR.

---

## Implementation gate

No format behavior may move from an unresolved assumption into the parser hot
path without one of:

- a normative rule;
- a documented compatibility decision plus test;
- an explicit unsupported/error state.

The matrix is therefore part of the implementation contract. New parser code
must link its non-obvious assumptions to a row here or to a more specific ADR.
