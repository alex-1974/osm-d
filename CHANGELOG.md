# Changelog

All notable changes to this project will be documented here.

The project follows semantic versioning once the public API reaches its first
stable release.

## Unreleased

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


### Added

- Initial repository structure.
- Data-integrity contract.
- Performance and benchmark contracts.
- Architecture documentation and initial ADR set.
- Minimal DUB library package root.
- Verified OSM specification/implementation compatibility matrix and reference catalogue.
- Allocation-free checked integer helpers and initial protobuf wire primitives: bounded cursor, varint/ZigZag decoding, field-key parsing and primitive field skipping.
