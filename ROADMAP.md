# Roadmap

## Tracked delivery milestones

Delivery work is organized into tracked milestones. GitHub goal/release issues
are the canonical trackers; each contains the current checklist and exit
criteria.

- **M3 — Close the production PBF reader:** #43
- **M4 — Loss-aware PBF round trip:** #44
- **M5 — XML and osmChange interoperability:** #45
- **M6 — Compact editable OSM store:** #46
- **M7 — First stable standalone release:** #47
- **M8 — API ergonomics and workspace primitive reuse:** #94
- **M9 — Editable store ↔ change/upload bridge:** #100
- **M10 — v0.2.0 release stabilization and API freeze:** #102
- **M11 — OSM API diffResult codec:** #114
- **M12 — Editing API capabilities discovery:** #119
- **M13 — v0.3.0 API freeze and release qualification:** #121
- **M14 — Consumer traversal, ranges and source ergonomics:** #129
- **M15 — Dataset integrity and OSM topology resolution:** #133
- **M16 — Complete OSM objects and area assembly:** #138
- **M17 — Changesets and OSM Editing API protocol:** #143
- **M18 — History, authoritative refresh and conflict foundation:** #148
- **M19 — OSM replication and incremental synchronization:** #153

Roadmap checkboxes describe capabilities or decisions, not mandatory
implementation for its own sake. Conditional optimizations such as a worker
arena or PGO are implemented only when measured evidence justifies them.

## Phase 0 — Contracts and evidence

- [x] Define data-integrity contract.
- [x] Define performance/scalability contract.
- [x] Define benchmark methodology.
- [x] Record initial architecture ADRs.
- [x] Complete OSM specification/real-world compatibility matrix.
- [x] Fix supported D compiler/version policy.
- [x] Select immutable benchmark datasets and hashes.

## Phase 1 — Wire and memory foundation

- [x] Checked endian helpers. #49
- [x] Bounded byte cursor.
- [x] Protobuf varint and ZigZag decode.
- [x] Protobuf field scanner.
- [x] Correct support for packed, unpacked and segmented repeated scalars.
- [x] Structured non-allocating decode errors.
- [x] Worker-local linear arena decision — not required for M3; revisit only on measured allocation/peak-memory pressure. #51
- [x] Reusable owned/borrowed block buffers.
- [x] Fuzz and malformed-input harnesses for the wire layer. #50

## Phase 2 — PBF vertical slice

- [x] File framing and resource limits.
- [x] Blob decompression abstraction.
- [x] HeaderBlock and feature negotiation.
- [x] PrimitiveBlock layout scan.
- [x] Zero-copy StringTable view.
- [x] DenseNodes decode.
- [x] DenseInfo decode.
- [x] Normal Node decode.
- [x] Way decode.
- [x] Relation decode.
- [x] Borrowed `ElementView` identity contract and PBF view conformance.
- [x] PBF structural and per-element preflight validation.
- [x] First single-thread comparison with libosmium.

## Phase 3 — Production PBF reader

Tracked by M3: #43.

- [x] Bounded producer/worker pipeline.
- [x] Parallel decompression and decode.
- [x] Ordered parallel element-delivery decision — borrowed merge deferred by ADR 0017; direct owned/store construction tracked in #64.
- [x] Public D range/foreach adapters.
  - [x] Node `foreach` adapter.
  - [x] Way `foreach` adapter.
  - [x] Relation `foreach` adapter.
- [x] Direct sink API.
- [x] `@nogc` hot-path audit.
- [x] Peak-memory benchmark.
- [x] Thread-scaling benchmark.
- [x] Profile-guided optimization decision — deferred until a stable consumer workload exposes a material opportunity. #51
- [x] Reconcile reader documentation and retire absorbed Phase 3 branches; preserve `research-integration`. #52

## Phase 4 — Raw/loss-aware round trip

Tracked by M4: #44.

- [x] Owned/raw loss-aware representation contract. #53
- [x] Unknown-field/feature preservation policy implemented. #54
- [x] PBF writer. #55
- [x] Semantic and differential round-trip qualification. #56

## Phase 5 — XML and osmChange

Tracked by M5: #45.

- [x] XML/osmChange mapping and modification semantics. #57
- [x] Streaming OSM XML reader/writer. #58
- [x] osmChange reader/writer. #59
- [x] Complete-object validation and JOSM/iD interoperability. #60

## Phase 6 — Compact store

Tracked by M6: #46.

- [x] City-scale random-access store contract and workloads. #61
- [x] Select and implement compact element storage layout. #62
- [x] Node/way/relation lookup and parent indexes. #63
- [x] Direct PBF-to-store construction and city-scale qualification. #64

Structure-of-arrays and `mir.ndslice` remain candidate implementation
techniques, not roadmap deliverables. They are used only if #62 shows a
consumer-relevant advantage.

## Phase 7 — Stable standalone library

Tracked by M7: #47.

- [x] Public API and compatibility-policy audit. #65
- [x] Consumer documentation, examples and package smoke tests. #66
- [x] Compatibility and performance baseline published. #67
- [x] Release gate and first tagged release. #69


## Phase 8 — API ergonomics and workspace reuse

Tracked by M8: #94.

- [x] Unify PBF/store leaf semantic view vocabulary.
- [x] Adopt `NodeRefView` / `OwnedNodeRef` terminology.
- [x] Add direct typed store lookup while preserving stable handles.
- [x] Add one-shot PBF convenience and focused `osm.pbf` facade.
- [x] Reconcile consumer docs, migration probes and package surface.
- [x] Complete workspace primitive reuse audit and preserve only contract-matching dependencies.


## Phase 9 — Editable store ↔ change/upload bridge

Tracked by M9: #100.

- [x] Define lifecycle-to-change extraction contract. #96
- [x] Implement deterministic sparse edit materialization. #97
- [x] Model and apply authoritative diff-upload results. #98
- [x] Qualify store → osmChange/validation → result → store round trip. #99

The bridge remains format-neutral. HTTP, OAuth, changeset creation/closing,
retry policy, editor undo/history and application worksets remain outside
osm-d.


## Phase 10 — v0.2.0 release stabilization and API freeze

Tracked by M10: #102.

- [x] Cut `release/0.2` from the exact post-M9 feature-freeze commit.
- [x] Audit the preferred facade/direct-import surface and freeze the v0.2.x
  source contract.
- [x] Finalize v0.1 -> v0.2 migration guidance and compatibility aliases.
- [x] Prepare v0.2.0 version intent, changelog, release notes and release
  evidence baseline.
- [x] Make release metadata checks derive the compatibility line from
  `RELEASE_VERSION`.
- [x] Pass the full six-compiler Release Gate and package/archive smoke.
- [x] Pass pinned real-data PBF round-trip and city-scale store qualification.
- [x] Promote `release/0.2` to `main` with a merge commit.
- [x] Verify the annotated v0.2.0 tag, GitHub Release, archive/checksum and
  post-release consumer state.

Feature/API freeze checkpoints are immutable engineering evidence. The final
release tag alone is the publication trigger.


## Phase 11 — OSM API diffResult codec

Tracked by M11: #114.

- [x] Define the current OSM API diffResult wire contract and upstream evidence. #111
- [x] Implement bounded streaming/materialized diffResult parsing and the
  focused `osm.upload` facade. #112
- [x] Qualify current server result shapes, duplicate placeholders,
  conditional-delete semantics and parser -> store reconciliation. #113

The codec ends at the successful OSM Editing API response body. HTTP,
authentication/OAuth, changeset creation/closing, retry policy and
application/editor state remain outside osm-d.


## Phase 12 — Editing API capabilities discovery

Tracked by M12: #119.

- [x] Define the editing/upload capability projection and current server
  evidence. #116
- [x] Implement bounded XML capability parsing and direct
  `CapabilityProfile` mapping. #117
- [x] Qualify current Rails structure, service states, unrelated/future
  capability siblings and capabilities -> upload validation. #118

The projection consumes dynamic target-server policy without turning osm-d
into an HTTP/account client. JSON capability responses remain additive future
work only if a real consumer requires them.


## Phase 13 — v0.3.0 API freeze and release qualification

Tracked by M13: #121.

- [x] Cut `release/0.3` from the exact post-M12 feature-freeze commit.
- [x] Audit the v0.3 public facade/direct-import surface and remove the
  ambiguous v0.2-only `UploadResultEntry.action` compatibility guess.
- [x] Freeze the v0.3.x source contract and v0.2 -> v0.3 migration guidance.
- [x] Prepare v0.3.0 version intent, changelog, consumer docs and release notes.
- [x] Pass the full six-compiler Release Gate and package/archive smoke.
- [x] Pass pinned real-data PBF round-trip and city-scale store qualification.
- [x] Promote `release/0.3` to `main` with a merge commit.
- [x] Verify the annotated v0.3.0 tag, GitHub Release, archive/checksum and
  post-release qualification.
- [x] Forward-integrate the release result to `develop`.

M11/M12 are the complete feature set for v0.3.0. No HTTP/OAuth client,
changeset lifecycle, JSON capability codec or other new feature family is
admitted after this feature freeze.


## Phase 14 — Consumer traversal, ranges and source ergonomics

Tracked by M14: #129.

- [x] Add exact zero-allocation tag lookup helpers over semantic tag ranges. #126
- [x] Qualify compact-store traversal ranges for idiomatic Phobos composition. #127
- [x] Evaluate composable push filtering for PBF foreach traversal without
  converting the push decoder into a Phobos InputRange. #128
- [x] Add bounded PBF reading from `transport-d.ByteSource` while preserving
  whole-buffer loss-aware semantics where required. #125

The direct statically dispatched `PbfReader.read(handler)` path remains the
maximum-throughput reference. Convenience composition is admitted only when its
lifetime and performance costs are explicit and measured.

M14 closes with three deliberately different consumer surfaces:

- resident PBF bytes use the push/foreach adapters and optional `where!`;
- bounded resources use `PbfReader.read(ByteSource, workspace, handler, ...)`
  so source ownership, reusable scratch and diagnostics remain explicit;
- owned store data uses ordinary D InputRanges, with direct traversal retained
  for measured hot loops.

No source-backed `pbfNodes/pbfWays/pbfRelations` opApply family was added:
it would hide per-traversal workspace ownership or require a new stateful
borrowing API merely for syntax. Loss-aware `PbfDocument` intentionally
remains whole-buffer.


## Phase 15 — Dataset integrity and OSM topology resolution

Tracked by M15: #133.

- [x] Define complete versus partial dataset/reference validity. #130
- [x] Add ordered, cycle-safe OSM reference resolution and topology traversal. #131
- [x] Qualify dataset validation and topology resolution on real OSM workloads. #132

OSM identity/reference topology belongs here. Generic geometry algorithms,
geodesy and spatial indexing remain separate workspace responsibilities.


## Phase 16 — Complete OSM objects and area assembly

Tracked by M16: #138.

- [x] Define the complete-object and OSM-to-geometry boundary. #134
- [x] Add complete Way and Relation resolution views/results. #135
- [x] Implement OSM-specific area and multipolygon assembly semantics. #136
- [x] Qualify complete objects and area assembly against real OSM data. #137

OSM member/ring assembly may produce geometry-ready coordinate sequences, but
robust generic polygon operations remain in `geo-d`.


## Phase 17 — Changesets and OSM Editing API protocol

Tracked by M17: #143.

- [x] Revise the v0.3 Editing API boundary so osm-d owns OSM protocol semantics
  while generic network execution remains in `transport-d`. #139
- [x] Add a first-class OSM Changeset semantic model and XML codecs. #140
- [x] Implement the Editing API protocol client over generic HTTP transport. #141
  - [x] `osm.api` exposes an explicit-server `EditingApiClient` over the
    replaceable `transport-d 0.2.x` `HttpExchange` boundary.
  - [x] capabilities/permissions, Node/Way/Relation current/version/history/full,
    Changeset create/read/update/close and osmChange upload are covered.
  - [x] Authorization remains request-scoped in sensitive transport headers;
    osm-d does not persist credentials or own OAuth/account/retry policy.
- [x] Qualify Changeset and Editing API protocol semantics. #142
  - [x] transport-independent semantic pipeline: Changeset -> store changes ->
    capability validation -> osmChange -> diffResult -> store reconciliation.
  - [x] current/version/history/full XML response shapes for Node/Way/Relation
    reuse the existing semantic OSM XML reader.
  - [x] deterministic fake-exchange qualification covers methods, paths,
    headers, bounded request/response bodies, 409/412/429/503 HTTP semantics,
    transport failure, response-decoding failure and local validation.
  - [x] external DMD/LDC consumer compilation qualifies the focused
    `import osm.api;` surface.

Credential persistence remains in `credentials-d`; OAuth2/PKCE, account
selection, retry/backoff and editor workflow remain outside the osm-d core.


## Phase 18 — History, authoritative refresh and conflict foundation

Tracked by M18: #148.

- [x] Define an OSM element history/version-sequence model distinct from editor
  undo history. #144
  - [x] typed Node/Way/Relation histories preserve ordered versions, explicit
    complete/partial coverage and deleted visibility without inventing missing
    deleted-Node coordinates.
  - [x] M17 specific-version and /history reads project directly into historical
    values; gaps remain explicit rather than being sorted/repaired.
- [x] Add authoritative server refresh and coherent store reconciliation. #145
  - [x] supplied authoritative batches preflight before mutation, preserve
    local-only/conflicting edits, support remote insert/delete/revival and reuse
    existing stable-handle/primary/parent-index machinery.
  - [x] local negative-ID creates remain isolated from positive server identity
    refresh; authoritative deletions are not re-uploaded as local deletes.
- [x] Implement structured three-way base/local/remote conflict classification. #146
  - [x] deterministic tag, Node coordinate, ordered Way-ref and Relation-member
    facts distinguish local/remote/identical/independent/overlapping changes.
  - [x] conservative classification never claims an automatic merge when
    independence cannot be proved.
- [x] Qualify refresh, history and conflict workflows. #147
  - [x] DMD 2.111.0 / LDC 1.41.0 runtime and external-consumer gates cover
    history, deletion, clean/dirty reconciliation, index coherence, batch
    preflight and M17 integration.
  - [x] LDC release-mode editor-scale timing evidence records conflict
    classification and authoritative refresh without adding speculative caches.

osm-d reports OSM synchronization facts and conflicts; the application decides
how to present or resolve them. See ADR 0033 for the synchronization boundary.


## Phase 19 — OSM replication and incremental synchronization

Tracked by M19: #153.

- [x] Define replication state, sequence, continuity and replay semantics. #149
  - [x] sequence continuity is sequence-number based; timestamps remain
    synchronization metadata and do not imply wall-clock arithmetic.
  - [x] replay/stale/gap and per-object version semantics are explicit, with an
    application-owned feed identity/checkpoint boundary.
  - [x] ADR 0034 fixes the M18 handoff, staged-apply transaction boundary and
    transport/compression ownership; independent state fixtures record the
    accepted state-file subset.
- [x] Implement state/path handling and transactional osmChange application. #150
  - [x] bounded state.txt parsing retains only sequence/timestamp semantics and
    ignores generator-internal properties.
  - [x] canonical nine-digit relative resource paths and explicit
    next/replay/stale/gap/feed-mismatch classification are public through
    `osm.replication`.
  - [x] decoded osmChange entries are staged per identity/version before
    mutation; replay/stale data are idempotent, gaps/payload mismatches fail,
    and local M18 conflicts abort before the first visible store change.
  - [x] only successful final reconciliation returns an advanced checkpoint;
    DMD/LDC runtime and external-consumer gates qualify the surface.
- [x] Compose bounded ByteSource + streaming GZIP + osmChange ingestion. #151
  - [x] `compression-d 0.3.x` provides the admitted caller-owned streaming
    GZIP contract; osm-d does not duplicate DEFLATE/GZIP.
  - [x] a bounded decoded `ByteSource` bridges GZIP output into the existing
    dxml/osmChange ForwardRange contract, replaying from compressed offset zero
    only when a saved parser cursor requests an older decoded block.
  - [x] CRC/ISIZE, truncation, concatenated-member/trailing-garbage and
    expansion-limit failures are distinguished from transport and osmChange
    failures before any store mutation.
  - [x] `applyGzipReplicationStep` retains the #150 complete-document staging
    boundary and advances the checkpoint only after successful semantic apply.
- [ ] Qualify continuity, replay, restart and incremental store updates. #152

Generic resource retrieval stays in `transport-d`; GZIP belongs in
`compression-d`; scheduling, retry policy and checkpoint persistence remain
application responsibilities.
