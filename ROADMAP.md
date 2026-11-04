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
