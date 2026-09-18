# Roadmap

## Phase 0 — Contracts and evidence

- [x] Define data-integrity contract.
- [x] Define performance/scalability contract.
- [x] Define benchmark methodology.
- [x] Record initial architecture ADRs.
- [x] Complete OSM specification/real-world compatibility matrix.
- [ ] Fix supported D compiler/version policy.
- [ ] Select immutable benchmark datasets and hashes.

## Phase 1 — Wire and memory foundation

- [ ] Checked endian helpers.
- [x] Bounded byte cursor.
- [x] Protobuf varint and ZigZag decode.
- [x] Protobuf field scanner.
- [x] Correct support for packed, unpacked and segmented repeated scalars.
- [x] Structured non-allocating decode errors.
- [ ] Worker-local linear arena.
- [ ] Reusable owned/borrowed block buffers.
- [ ] Fuzz and malformed-input harnesses for the wire layer.

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
- [ ] Relation decode.
- [ ] Borrowed `ElementView` API.
- [ ] Structural validation.
- [ ] First single-thread comparison with libosmium.

## Phase 3 — Production PBF reader

- [ ] Bounded producer/worker pipeline.
- [ ] Parallel decompression and decode.
- [ ] Ordered merge mode.
- [ ] Public D range adapter.
- [ ] Direct sink API.
- [ ] `@nogc` hot-path audit.
- [ ] Peak-memory benchmark.
- [ ] Thread-scaling benchmark.
- [ ] Profile-guided optimization only after baseline stability.

## Phase 4 — Raw/loss-aware round trip

- [ ] Raw representation for otherwise unrepresentable input.
- [ ] Unknown-field/feature preservation policy implemented.
- [ ] PBF writer.
- [ ] Semantic round-trip comparator.
- [ ] Differential round-trip tests.

## Phase 5 — XML and osmChange

- [ ] Streaming OSM XML reader.
- [ ] OSM XML writer.
- [ ] osmChange reader/writer.
- [ ] API-complete-object validation for modifications.
- [ ] JOSM/iD interoperability fixtures.

## Phase 6 — Compact store

- [ ] City-scale random-access store design.
- [ ] Structure-of-arrays experiments.
- [ ] Node/way/relation lookup indexes.
- [ ] Parent-way and parent-relation indexes.
- [ ] Direct PBF-to-store sink.
- [ ] `mir.ndslice` experiments for numerical/columnar operations.
- [ ] City-store-build benchmark and memory target.

## Phase 7 — Stable standalone library

- [ ] Public API review.
- [ ] Documentation and examples.
- [ ] Compatibility corpus.
- [ ] Performance baseline published.
- [ ] Semantic versioning/release policy.
- [ ] First tagged release.
