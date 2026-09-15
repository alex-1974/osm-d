# Changelog

All notable changes to this project will be documented here.

The project follows semantic versioning once the public API reaches its first
stable release.

## Unreleased

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

- Initial repository structure.
- Data-integrity contract.
- Performance and benchmark contracts.
- Architecture documentation and initial ADR set.
- Minimal DUB library package root.
- Verified OSM specification/implementation compatibility matrix and reference catalogue.
- Allocation-free checked integer helpers and initial protobuf wire primitives: bounded cursor, varint/ZigZag decoding, field-key parsing and primitive field skipping.
