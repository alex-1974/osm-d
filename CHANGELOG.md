# Changelog

All notable changes to this project will be documented here.

The project uses semantic versioning. During the pre-1.0 period, the current
supported source-compatibility contract is defined in `docs/API_STABILITY.md`.

## Unreleased

### Added
- Add focused `osm.sync` M18 synchronization semantics: typed complete/partial
  Node/Way/Relation histories, direct M17 /history projections, explicit
  base/local/remote conflict classification, conservative ordered Way/Relation
  edit-span detection, and preflighted authoritative `OsmStore` reconciliation
  that preserves local edits and existing index/handle contracts.
- Add focused `osm.api` OSM Editing API 0.6 protocol client over the generic
  `transport-d 0.2.x` `HttpExchange`: explicit server selection,
  capabilities/permissions, Node/Way/Relation current/version/history/full,
  Changeset create/read/update/close, bounded osmChange upload and diffResult
  parsing, request-scoped Authorization, exact HTTP/OSM status classification,
  bounded error diagnostics, and deterministic fake-exchange qualification.
- Add focused `osm.area` structural area/multipolygon assembly: exact
  Node-ID Way joining, explicit outer/inner roles, reversible source-Way
  traversal with provenance, multiple rings, owning path results, and
  distinct partial/ambiguous/invalid diagnostics for missing data, dangling
  chains and multiply-connectable junctions.
- Add focused `osm.complete` borrowed complete-object projections for
  `OsmStore` and indexed `OwnedDataset`, including resolved Way Nodes and
  typed Relation members, direct complete/partial/invalid status,
  identity-based closed-Way detection, and exact nanodegree
  `LocationBounds`.
- Add focused `osm.topology` resolution and bounded closure traversal:
  ordered Way/Relation resolution, explicit `OwnedDatasetIndex`, cycle-safe
  Relation child closure, distinct parent closure over maintained reverse
  indexes, and caller-visible traversal workspace/limits/status.
- Add explicit complete/partial dataset-reference validation for
  `OwnedDataset` and `OsmStore` through `osm.validate`, including
  deterministic missing/local/deleted-reference diagnostics.

- Add exact, allocation-free `findTag`, `hasTag` and `tagEquals` helpers
  for borrowed OSM tag ranges. The free functions are UFCS-friendly, preserve
  duplicate ordering, compare D strings as their existing UTF-8 code units and
  perform no normalization or transcoding.
- Qualify compact-store element, child and parent traversal values as lazy D
  InputRanges and document cursor-copy and structural-mutation invalidation
  semantics for Phobos composition.
- Add `where!` push filtering for `pbfNodes`, `pbfWays` and
  `pbfRelations`. The compile-time predicate filters callback-scoped borrowed
  elements without materialization while preserving foreach early-exit,
  completion and validation semantics.
- Add bounded `transport-d.ByteSource` overloads for `PbfReader.read`,
  `readPbf` and direct `readPbfStore`. Incremental PBF framing retains only
  the current BlobHeader/Blob plus reusable decoder scratch, keeps whole-buffer
  overloads intact, and reports transport failures separately from
  malformed/truncated PBF.

## 0.3.0 - 2026-11-04

### Added

- Add the focused `osm.upload` facade and bounded transport-d/dxml reader for
  OSM API 0.6 `diffResult` responses. The codec preserves root metadata,
  source order, duplicate placeholder identities and raw old/new ID/version
  fields without inferring request actions from response shape.
- Add transactional `readUploadResult` / `readUploadResultDocument`
  conveniences, explicit response limits/diagnostics, current server-shape
  regression coverage and an external parser -> `OsmStore.applyUploadResult`
  consumer probe.
- Add the focused `osm.capabilities` facade and bounded XML projection of OSM
  Editing API capabilities into the existing `CapabilityProfile`.
  Way-node, Relation-member and Changeset-element limits now come from
  target-server policy instead of caller hardcoding; API version range,
  service state and timeout remain available for editing consumers.
- Add an explicit forward-compatible projection policy for unrelated
  capabilities: projected fields fail closed while map/Notes/GPX query policy,
  imagery rules and future unrelated subtrees are boundedly skipped.

### Changed

- Remove the ambiguous context-free `UploadResultEntry.action` compatibility
  property. Current OSM diffResult shapes cannot identify request action
  reliably; v0.3 consumers use
  `UploadResultEntry.effectFor(uploadedEntry, effect)` with exact request
  context.

### Fixed

- Correct the compatibility-contract inventory to include
  `UploadResultEffect`, which became public in v0.2.1.

## 0.2.1 - 2026-11-04

### Fixed

- Correct OSM API diff-result interpretation for conditional
  `delete if-unused`: a successful response may retain an object and return
  `old_id`, `new_id` and `new_version` instead of confirming deletion.
  `UploadResultEntry.effectFor` now classifies acknowledgements against the
  exact uploaded request entry, and `OsmStore.applyUploadResult` restores a
  retained object's clean baseline rather than invalidating its handle.
- Accept bare delete-shaped diff-result entries with negative placeholder IDs
  and document that general diff results may repeat type+oldId when placeholders
  are reused. The existing context-free `UploadResultEntry.action` property
  remains source-compatible but is explicitly only a legacy shape guess.

## 0.2.0 - 2026-11-04

### Added

- Add the M9 editable-store change/upload bridge. `OsmStore.collectChanges`
  materializes sparse pending edits as deterministic, dependency-safe
  `OwnedChangeSequence` values without scanning the complete loaded store or
  inventing a changeset ID. Local create-then-delete edits are cancelled;
  established deletes retain authoritative baseline version metadata.
- Add format-neutral `UploadResultEntry` / `UploadResult` values and
  `OsmStore.applyUploadResult`. Reconciliation preflights the exact uploaded
  snapshot before mutation, preserves handles for create/modify, remaps
  authoritative create IDs through existing parent indexes, records returned
  versions/explicit changesets, and invalidates handles for confirmed deletes.
- Add end-to-end store → osmChange write/read → upload validation → simulated
  diff-result → store qualification, including local Node/Way/Relation
  dependencies, Relation topological ordering, stale-response atomicity and
  delete-baseline behavior.

### Changed

- Simplify the developing v0.2 consumer surface: `NodeRefView` /
  `OwnedNodeRef` replace the ambiguous Way-node names, compact-store ranges
  return the same semantic leaf values as PBF, and typed
  `store.node/way/relation(id, ...)` lookup avoids a mandatory handle round
  trip for ordinary reads.
- Add one-shot `readPbf` and `pbfNodes/pbfWays/pbfRelations` convenience
  entry points while preserving the reusable-workspace `PbfReader.read` hot
  path.
- Add focused `osm.pbf` and `osm.compare` facades for PBF-specialized and
  serialization-independent semantic comparison workflows respectively; slim
  `import osm;` to ordinary semantic/PBF-traversal/store concepts.
- Audit workspace reuse: retain transport-d as the byte-resource boundary;
  defer containers-d queue reuse because its producer-admission contract does
  not match PBF blocking backpressure; defer compression-d until it has a
  stable qualified release; avoid importing concurrency-d's broader executor
  policy for this reader slice.


## 0.1.0 - 2026-11-04

- Added `PbfParallelReader.readSummary`, a bounded producer/worker whole-buffer
  PBF path for parallel OSMData decompression, complete semantic validation, and
  aggregate counting. Queued jobs borrow immutable Blob slices from the input;
  each worker owns and reuses one `PbfReaderWorkspace`; the queue has fixed
  capacity; worker failures are reduced to the deterministic earliest file
  block; and no borrowed semantic element crosses a worker boundary.
  `PbfReader.read` remains the ordered consumer-sink API.
- Added durable PBF memory/allocation and thread-scaling benchmarks. Fast CI
  compiles both benchmark targets on DMD 2.111.0 and LDC 1.41.0; the scaling
  runner verifies serial/parallel summary parity before reporting elapsed time,
  speedup, and peak RSS.

- Added semantic Way and Relation `foreach` adapters through
  `PbfReader.ways` and `PbfReader.relations`. Both use D `opApply` over
  the synchronous push decoder, preserve exact early-stop control, retain
  whole-file validation on natural completion, and expose borrowed
  `WayView`/`RelationView` values without per-element materialization.
  External `@safe` consumer probes and DIP1000 compile-negative tests cover
  iterable/input and callback-view lifetime escapes. Final Bremen LDC 1.41.0
  qualification matched direct-sink semantics exactly and measured median
  convenience overheads of +5.23% (Way core), +4.63% (Way full), +4.84%
  (Relation core), and +5.21% (Relation full). The direct sink remains the
  primary maximum-throughput API.

- Added a node-only semantic `foreach` adapter through `PbfReader.nodes`.
  The adapter uses D `opApply` over the existing synchronous push decoder,
  yields the same borrowed `NodeView` for regular and DenseNodes encoding,
  propagates real foreach early-stop control, and performs no per-node
  materialization. Complete traversal preserves whole-file validation; early
  exit explicitly leaves the unvisited suffix unvalidated. DMD 2.111.0 and
  LDC 1.41.0 compile/lifetime gates reject iterable and `NodeView` escapes.
  Controlled Bremen LDC 1.41.0 comparison with the direct sink measured median
  deltas of +0.77% for core access and -0.21% for tag traversal, treated as
  performance parity.


- Unified regular Node and DenseNodes delivery at the high-level `PbfReader`
  boundary behind one concrete semantic `NodeView`. The callback-scoped view
  is a small non-copyable borrow over unchanged codec-specific representations;
  `node.tags` produces one independent zero-allocation cursor copy on demand.
  Controlled LDC 1.41.0 Bremen A/B qualification retained exact semantic parity
  and measured median deltas of -1.02% for core node access, -0.86% for tag-range
  materialization, and -0.62% for full node-tag traversal versus the pre-change
  baseline.

- Tightened the semantic reader boundary: direct PBF coordinate, Info/DenseInfo, raw provenance, and Way parallel ref/location representation fields are now package-internal while codec tests and benchmarks retain access. External `import osm;` compile probes verify that ordinary consumers use `location`, `metadata`, `nodes`, tags, and relation members instead.

- Added one format-independent `TagView` for regular and DenseNodes tags. Consumer-facing tags now expose only exact borrowed key/value bytes; PBF StringTable IDs remain inside codec ranges for validation and internal benchmark/diagnostic use, preserving the existing tag-ID benchmark semantics.

- Added format-independent `WayNodeView` and semantic `way.nodes` iteration. Way node IDs and optional `LocationsOnWays` coordinates are now presented as one ordered lazy range without allocation, node lookup, or geometry construction; the existing PBF `refs` / `locations` ranges remain available during the pre-1.0 transition.

- Fixed DIP1000 usability of borrowed reader ranges from `scope ref` callbacks. Normal tags, DenseNodes tags, Way references, Way locations, and relation members can now be iterated from external `@safe nothrow @nogc` consumers without `@trusted`; length-delimited wire traversal uses a scope-returning child cursor so backing slices remain lifetime-bound.

- Added format-independent `RelationMemberView` using `ElementType`, `OsmId`, and borrowed role bytes. PBF `role_sid` remains internal to StringTable decoding, and the duplicate public `RelationMemberType` enum no longer crosses the consumer boundary.

- Added format-independent `MetadataView` for OSM element version, timestamp, changeset, independently optional user ID/username, and visibility. Regular Node, DenseNodes-backed Node, Way, and Relation views expose the same `metadata` property without changing decoder storage; raw PBF timestamp units and StringTable IDs remain below the consumer boundary.

- Added format-independent `LocationView` with exact nanodegree access and lazy latitude/longitude degree conversion. Regular and DenseNodes-backed node views now expose the same `location` property, optional `LocationsOnWays` coordinates reuse the same semantic type, and the curated `osm` root exports `OsmId`, `ElementType`, and `LocationView` for consumer discovery.

- Optimized regular Way decoding with a package-internal caller-owned preflight
  plan that reuses canonical packed-field locations during emission while
  preserving the generic protobuf fallback and fail-closed group semantics.
  Final qualified Bremen whole-PBF decoding was 26.5% faster than the clean
  production baseline with LDC 1.41.0; four pinned real-data extracts retained
  exact semantic parity with the baseline and libosmium reference.

- Added allocation-free regular Relation decoding with complete group preflight,
  borrowed ordered member ranges, packed/unpacked segmented member-column
  compatibility, checked delta-coded member IDs, StringTable-validated roles,
  explicit NODE/WAY/RELATION member types, duplicate/order preservation, and
  failure-before-first-sink semantics.

- Reused the construction-controlled validated-state proof carried by
  `DenseTagRange` while decoding tag pairs. A10b removes repeated String-ID
  domain/range validation after the same IDs have already been proved valid,
  while retaining cursor decoding and defensive `StringTableView.get()` bounds
  checks. Stable-gated A-B-B-A measurements favored A10b in all nine measured
  tagged cells; targeted repeats confirmed the noisier boundary cases. The
  benchmark executable `.text` decreased by another 1,088 bytes.

- Extended the DenseNodes benchmark contract with explicit `info-only`,
  `typical-info`, and `rich-info` workloads. All three sink paths now make
  DenseInfo observable, while the C++20 semantic reference mirrors complete
  metadata preflight and streaming emission. D, GCC C++, and Clang C++ matched
  all 21 profile/path checksum cells; the historical `--profile=all` set remains
  unchanged for A2-A10 reproducibility. This establishes A11 measurement
  infrastructure only and makes no performance claim.

- Corrected the A11 DenseInfo benchmark fixture so generated `visible` values
  are consistently `true` in both the D workload builder and C++20 semantic
  reference. The initial shared alternating `true`/`false` fixture escaped
  cross-implementation parity because both generators contained the same
  defect. After correction, the metadata-profile checksums changed as expected,
  the four historical profiles remained unchanged, and D/GCC/Clang again
  matched all 21 profile/path checksum cells. Pre-correction A11 timings are not
  used as the frozen performance baseline.

- Added a package-internal prevalidated DenseInfo emission path after complete
  `validateDenseInfo()` preflight. The public cursor remains defensive, while
  internal DenseNodes emission avoids repeating already-proved cumulative
  arithmetic, timestamp-scaling, UID-domain, and `user_sid`-domain checks.
  Wire/cursor checks and defensive StringTable materialization remain intact.
  Against the corrected A11 benchmark contract, all 21 baseline/candidate
  semantic checksum cells matched, executable `.text` decreased by 3,752
  bytes, and all nine controlled DenseInfo A-B-B-A cells favored the candidate
  by 3.2-8.2%. All mirrored halves and all nine sentinel-normalized comparisons
  also favored the candidate; the global sentinel 3% gate remained `REVIEW`
  because of isolated excursions.

- Added a package-internal prevalidated DenseTags node-partition path used only
  after successful complete `validateDenseTags()` preflight. The public
  `DenseTagNodeCursor.nextNode()` remains defensive, while production
  DenseNodes emission avoids repeating StringTable-ID semantic validation for
  every non-zero `keys_vals` value during node partitioning. Controlled A10a
  A-B-B-A measurements improved all nine tagged benchmark combinations by
  5.3–12.7% and reduced executable `.text` by 5,408 bytes.

- Reused the already validated sole `DenseNodes` payload for implicit-all-tagless
  coordinate cursors, eliminating one redundant outer `PrimitiveGroup` scan
  while preserving the generic path for tagged, explicit-delimiter-only,
  repeated, and unrepresentable-large payloads. Controlled A8e benchmarks show
  a roughly 75–98 ns/group fixed saving for small and medium tagless groups and
  measurement-neutral behavior once that fixed cost is amortized.

- Added allocation-free DenseInfo decoding with independently optional metadata columns, packed/unpacked compatibility, checked delta/timestamp arithmetic, StringTable-validated usernames, and explicit presence semantics.
- Added compile-time-specialized DenseNodes emission, a scalar sink fast path for tag-/metadata-free groups, and targeted hot-path inlining without weakening preflight validation.
- Added a specialized DenseNodes dispatch boundary that keeps all four tag/DenseInfo variants out of the public decoder while preserving inlining inside the selected hot loop.
- Optimized validated DenseNodes emission by removing redundant per-node checked coordinate/delta arithmetic and successful status rewrites, and added a package-internal failure-only `sint64` decode path without changing the public wire-status contract.
- Optimized completed DenseNodes summary publication by replacing the per-node node-count update with one post-emission assignment from the validated layout, and documented that decode summaries are defined only after successful completion.
- Added semantic C++ DenseNodes reference, coordinate-stage and varint-core performance diagnostics, and documented the 2026-09-13 LDC baseline.

- Added Ddoc/DDox documentation policy and documented the initial wire API.
- Ignore the generated `d-osm-test-library` dub test runner.
- Added the first reproducible varint microbenchmark with pointer-vs-slice comparison and DMD/LDC runner.
- Hardened varint benchmark methodology with warm-up, ABBA ordering, robust quantiles, optional CPU affinity and thermal snapshots.
- Added an experimental library slice cursor/varint decoder and three-way pointer vs library-slice vs local-slice benchmark.
- Moved benchmark thermal snapshots to the actual post-build/post-cooldown measurement boundary and report SMT siblings when available.
- Marked the experimental library slice varint hot path for explicit cross-module inlining to isolate the library-boundary performance effect.
- Marked the production pointer varint hot path with the same explicit cross-module inlining hints for a fair final cursor comparison.
- Adopted a slice-backed production `WireCursor` after the fair inline benchmark showed performance parity with the pointer design; removed the experimental wire modules and recorded the decision in ADR 0008.
- Added zero-copy OSMPBF BlobHeader decoding and transactional file-block framing with hard resource limits and malformed/truncated-input tests.
- Added validated OSMPBF Blob decoding plus zero-copy raw and bounded zlib payload materialization into caller-owned buffers; optional codecs are recognized and fail explicitly until backends are configured.
- Added zero-copy OSMPBF HeaderBlock/HeaderBBox decoding, lazy ordered feature ranges, and explicit required-feature capability validation.
- Added allocation-free PrimitiveBlock first-pass layout decoding, borrowed PrimitiveGroup ranges, and caller-buffered O(1) StringTable indexing.
- Added allocation-free PrimitiveGroup/DenseNodes validation plus streaming ID/coordinate decoding with packed/unpacked compatibility, checked delta accumulation, and exact nanodegree conversion.
- Added preflighted zero-copy DenseNodes tag decoding with packed/unpacked `keys_vals` compatibility, strict delimiter/StringTable validation, and borrowed per-node tag ranges.
- Added a reproducible DenseNodes microbenchmark covering tagless, typical-tag, tag-rich and mixed profiles with coordinate-only, tag-ID and tag-byte sink paths.
- Added allocation-free DenseInfo decoding with independently optional metadata columns, packed/unpacked compatibility, checked delta/timestamp arithmetic, StringTable-validated usernames, and per-node metadata views.


### Added

- Add the M6 compact editable `OsmStore` with stable opaque handles,
  deterministic per-type traversal, typed expected-O(1) ID lookup,
  create/replace/delete/restore/revert lifecycle support, lazy edit baselines,
  pooled variable children, shared string interning, compact primary indexes,
  and deterministic ownership for the high-volume store core.
- Add reproducible pinned-Bremen store-layout qualification covering retained
  RSS/owned bytes, build cost, primary and parent lookup, full traversal,
  10,000 representative edits, parent-index rebuild, revert and local-ID
  remapping. ADR 0022 records the accepted #62 trade-off and evidence.
- Add production incremental parent indexes to `OsmStore`: distinct
  Node-to-Way and typed element-to-Relation navigation, coherent maintenance
  across add/replace/delete/restore/revert, and authoritative local-ID remap
  through `remapId`. ADR 0023 records the representation and Bremen trade-off.
- Add public transactional `readPbfStore` construction. Validated PBF semantic
  views feed the fully indexed compact store directly without a
  `PbfDocument`/`OwnedDataset` intermediate. Pinned Monaco, Liechtenstein and
  Bremen parity passed; Bremen direct construction was 2.29x faster than the
  materialized path with a 1.070x peak/final RSS ratio. ADR 0024 records the
  decision to keep M6 direct construction single-writer rather than add an
  unmeasured parallel staging/merge layer.

- Initial repository structure.
- Data-integrity contract.
- Performance and benchmark contracts.
- Architecture documentation and initial ADR set.
- Minimal DUB library package root.
- Verified OSM specification/implementation compatibility matrix and reference catalogue.
- Allocation-free checked integer helpers and initial protobuf wire primitives: bounded cursor, varint/ZigZag decoding, field-key parsing and primitive field skipping.
