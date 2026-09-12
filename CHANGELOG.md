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


### Added

- Initial repository structure.
- Data-integrity contract.
- Performance and benchmark contracts.
- Architecture documentation and initial ADR set.
- Minimal DUB library package root.
- Verified OSM specification/implementation compatibility matrix and reference catalogue.
- Allocation-free checked integer helpers and initial protobuf wire primitives: bounded cursor, varint/ZigZag decoding, field-key parsing and primitive field skipping.
