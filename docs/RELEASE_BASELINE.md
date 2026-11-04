# osm-d v0.2.0 release baseline

**Feature-freeze date:** 2026-11-04  
**Feature-freeze commit:** `fab28b1085138531ad07d95a48ad010d8300383e`

This document condenses the evidence relevant to the v0.2.0 release. v0.2 is
primarily a consumer-API and editable-store workflow release, not a parser
algorithm rewrite. Evidence is therefore split between unchanged v0.1
performance/reference baselines and v0.2-specific requalification of the
changed API/store surface.

Absolute timings are environment-specific. Durable claims are semantic parity,
bounded-memory behavior, the supported compiler matrix, source/lifetime
contracts and the measured performance class on the recorded runners.

## Publication record

v0.2.0 was promoted by release PR #103 with a merge commit:

- `main` release commit:
  `5bc4572452f1d68ff126d6bc5a8c734b59baeb6a`;
- annotated tag object:
  `4bd66459b985f208074ad7832f4ed3cbd53e26e6`;
- tag `v0.2.0` resolves exactly to the release commit above;
- Publish release run: 41855719421 — PASS;
- post-promotion Release Gate run: 41855719445 — PASS across all six compiler
  jobs, metadata and Monaco I/O;
- release archive: `osm-d-0.2.0.tar.gz`, 324,437 bytes;
- published archive digest:
  `sha256:a39c30037445529c48b345548ea098c4ef92adf9a14cbb0e1a04682bfa729d91`;
- checksum asset: `osm-d-0.2.0.tar.gz.sha256`.

The automated tag is annotated but unsigned. Workspace policy recommends
signed final release tags but does not make signing a release-gate requirement;
v0.1.0 used the same publication mechanism.

## Supported toolchain and platform

Source-compatibility floor:

- D frontend 2.111;
- DUB 1.40.0.

Release compiler matrix:

- DMD 2.111.0, 2.112.1, 2.113.0;
- LDC 1.41.0, 1.42.0, 1.43.0.

The v0.2.0 release gate is Ubuntu 24.04 x86_64. Other platforms are not
claimed as release-qualified by this baseline.

LDC 1.41.0 remains the primary release-performance compiler.

The supported source API and direct-import boundary are defined in
`API_STABILITY.md`; v0.1 -> v0.2 migration is documented in
`API_V0_2.md`.

## Pinned compatibility corpus

Real-data release evidence continues to use the Geofabrik 2026-09-01 snapshot.

| Dataset | Compressed bytes | SHA-256 |
| --- | ---: | --- |
| Monaco | 690,567 | `f2d904ee0aa156a2252c39c0ab80ca7b3fafb28da6a84b909084a26f068ac962` |
| Liechtenstein | 3,451,831 | `69e694d15ac822665381bf47fa8a5f437b3c0c3d72af458727f94e131930d818` |
| Bremen | 21,159,666 | `52bc46f09ce1f1198b95de308aba10c1b59108c9fdbb827fea305f7316b4ea0e` |
| Austria | 808,820,532 | `0bfa5f1db8a468b3792b1ead07b56d4f7a8c456e500d23dc8d3083e82508dfb8` |

The manifest and fetch/checksum tooling live under `benchmark/datasets` and
`benchmark/fetch-datasets.sh`.

## Parser/reference baseline carried forward from v0.1.0

The v0.2 API work does not change the production semantic decode algorithms
that established the v0.1.0 broad reference baseline.

The most recent full libosmium 2.23.0 decode-count comparison remains:

| Dataset | Nodes | Ways | Relations | Tags | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Monaco | 41,703 | 6,249 | 348 | 44,946 | PASS |
| Liechtenstein | 361,543 | 42,051 | 973 | 210,505 | PASS |
| Bremen | 1,662,874 | 328,626 | 5,985 | 2,073,595 | PASS |
| Austria | 87,627,541 | 9,359,891 | 180,296 | 43,979,849 | PASS |

v0.2 release qualification additionally executes the deterministic round-trip,
malformed-input and external-consumer gates across the supported compiler
matrix and a pinned Monaco/Liechtenstein/Bremen real-data round-trip gate on
the release branch.

This distinction is deliberate: the full Austria/libosmium count run remains
the broad parser baseline; the release branch requalifies the changed package
and API surface without pretending that unchanged historical timing values
were freshly remeasured.

## v0.2 editable-store qualification

M9 changes the store's edit/export/reconciliation behavior, so the final M9
feature tree was requalified with the production M6 city-scale gate before the
release branch was cut.

Evidence source:

- PR #101 final head `cd7cab5ec48f5ea41d6232362b6acdea51a23c95`;
- M6 Store Qualification run 41848897173;
- artifact digest
  `sha256:96506af046dd905ac052f2d31c34081a54bccfc8f4d3043dcadaf2e3581fde9c`;
- LDC 1.41.0, Ubuntu 24.04, release/allAtOnce.

Pinned semantic parity:

| Dataset | Reference checksum | Direct-store checksum | Result |
| --- | --- | --- | --- |
| Monaco | 18144549377310145839 | 18144549377310145839 | PASS |
| Liechtenstein | 4453202522050253806 | 4453202522050253806 | PASS |

Bremen production compact store:

- Nodes: 1,662,874;
- Ways: 328,626;
- Relations: 5,985;
- direct PBF -> indexed store: **2,284.842 ms**;
- materialized PBF + owned-store build: **5,391.110 ms**;
- materialized/direct ratio: **2.359511x**;
- final incremental RSS: **355,336 KiB = 347.008 MiB**;
- peak incremental RSS: **380,408 KiB**;
- peak/final ratio: **1.070559x**;
- logical owned bytes: **308,976,077**;
- parent-index logical bytes: **73,415,112**.

All semantic/edit/revert/remap checksums matched the straightforward reference
and `integrity=pass`. The direct path passes the <=1.5x peak/final gate, the
512 MiB city target and the 384 MiB stretch target.

The sparse M9 created-slot journals are empty for a freshly loaded baseline and
therefore do not impose a city-sized allocation proportional to the complete
dataset.

## Store -> change -> upload-result contract

The new M9 qualification covers:

- create/modify/delete lifecycle mapping;
- local create-then-delete cancellation;
- authoritative baseline version retention for established deletes;
- Node -> Way -> Relation dependency ordering;
- topological ordering of local Relation dependencies;
- explicit rejection of circular local Relation placeholders;
- osmChange write/read semantic round trip;
- upload-readiness validation;
- authoritative create-ID/version remapping;
- parent-index/reference coherence after remap;
- modify version acknowledgement;
- confirmed-delete handle invalidation;
- stale-response failure before partial acknowledgement.

The public model remains format-neutral. Network upload, OAuth/account policy
and changeset lifecycle are not release claims.

## Reader performance reference

The v0.1.0 Bremen reader measurements remain the current parser-performance
reference because v0.2 does not replace that hot path:

| Mode | p50 elapsed | Speedup vs serial | p50 peak RSS |
| --- | ---: | ---: | ---: |
| serial `PbfReader` | 700.879 ms | 1.00x | 28,580 KiB |
| parallel, 1 worker | 728.658 ms | 0.96x | 33,188 KiB |
| parallel, 2 workers | 387.254 ms | 1.81x | 34,104 KiB |
| parallel, 4 workers | 330.516 ms | 2.12x | 46,456 KiB |

Warmed reusable Bremen reader workspace measurements remain:

- second complete read: 0 D-GC bytes, 0 collections;
- third complete read: 0 D-GC bytes, 0 collections;
- dedicated-process peak RSS: 28,512 KiB.

The 808,820,532-byte Austria workload retained 0 D-GC bytes and 0 collections
on the second read with the same workspace.

These are regression/reference measurements, not cross-host latency SLAs.

## Release I/O evidence

The v0.2 release branch was measured on the pinned Monaco workload under
LDC 1.41.0, Ubuntu 24.04, release/allAtOnce.

Evidence source:

- release branch commit `4568d0db8a5add4ad0c813f00ae2a062e5f60546`;
- Release Gate run 41853554192;
- artifact `release-io-monaco-4568d0db8a5add4ad0c813f00ae2a062e5f60546`;
- artifact digest
  `sha256:47f0629149d6a1ad3c4dd9e0ef0ffbe905800c7689f543e617131deeca479228`.

The input contained 41,703 Nodes, 6,249 Ways and 348 Relations.
Generated sizes were 2,496,211 bytes for semantic PBF and 11,584,269 bytes
for OSM XML.

| Operation | v0.1.0 reference p50 | v0.2.0 release-branch p50 |
| --- | ---: | ---: |
| semantic PBF write | 136.201 ms | **104.310 ms** |
| OSM XML write | 273.119 ms | **211.524 ms** |
| materializing OSM XML read | 1,113.736 ms | **772.839 ms** |

`semantic_parity=pass`: both generated formats were read back and compared
semantically to the source `OwnedDataset`.

The cross-run timing improvement is reported as observed release evidence, not
as a causal performance claim: GitHub-hosted runner hardware and load are not
controlled across the v0.1 and v0.2 measurements.

## Release interpretation

v0.2.0 freezes the coherent high-level facade/API family, not every technically
importable implementation declaration.

Release claims remain narrower than the implementation:

- low-level wire/codec/store implementation modules are not
  compatibility-frozen;
- there is no persistent/mmap store format promise;
- store mutation is single-writer/external-sync;
- direct PBF store construction remains deliberately single-writer;
- no HTTP/OAuth/changeset lifecycle policy is introduced;
- platform qualification beyond Ubuntu 24.04 x86_64 remains future evidence.

Literal JOSM-export provenance #85 remains evidence hardening. v0.2.0 release
correctness relies on independently authored JOSM-/iD-compatible semantic
fixtures plus osmium-tool interoperability, not a claim of byte-identical editor
provenance.
