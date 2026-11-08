# osm-d release baseline

Absolute timings are environment-specific. Durable claims are semantic parity,
bounded-memory behavior, the supported compiler matrix, source/lifetime
contracts and the measured performance class on the recorded runners.

## v0.3.0 release and publication record

**Feature-freeze date:** 2026-11-04  
**Feature-freeze commit:** `77c98eaca6ba2cd8f50eb50adc4d4e352d6e719c`

v0.3.0 contains the completed M11/M12 Editing API response/policy slice:

- bounded `diffResult` XML parsing through `osm.upload`;
- request-context result classification through
  `UploadResultEntry.effectFor`;
- bounded Editing API capabilities projection through `osm.capabilities`;
- direct projection of dynamic Way/Relation/Changeset limits into the existing
  `CapabilityProfile`.

The production PBF decoder/writer, compact-store representation and city-scale
store algorithms are unchanged by M11/M12. Existing v0.2 performance/reference
evidence therefore remains the comparison baseline rather than being relabeled
as fresh v0.3 measurements.

v0.3-specific correctness evidence before the release branch:

- M11 final PR-head Fast CI 41896048308 — DMD 2.111.0 PASS,
  LDC 1.41.0 PASS;
- M11 post-merge Fast CI 41896622851 — PASS;
- M12 final PR-head Fast CI 41909701127 — DMD 2.111.0 PASS,
  LDC 1.41.0 PASS;
- M12 post-merge Fast CI 41910215373 — PASS;
- external `osm.upload` and `osm.capabilities` consumers compile and run on
  the fast compiler pair;
- server-shape fixtures cover conditional delete result ambiguity, placeholder
  reuse, current capability structure/service states, projection evolution and
  malformed/bounded input.

Release-branch stabilization evidence on candidate
`6475ead54f7fe1a4a701ac0232eb67a3ca2d7a9b`:

- Release Gate run 41914520052 — PASS across all six compiler jobs, metadata
  and Monaco I/O;
- PBF Round-trip Qualification run 41914520062 — PASS for pinned Monaco,
  Liechtenstein and Bremen;
- M6 Store Qualification run 41914520082 — PASS;
- Monaco I/O artifact
  `release-io-monaco-6475ead54f7fe1a4a701ac0232eb67a3ca2d7a9b`,
  digest
  `sha256:4541552189ecdd8c414420565102edd28beaf5a87c4ceb8ebea351eaac8fc24a`;
- M6/Bremen evidence artifact
  `store-layout-bremen-6475ead54f7fe1a4a701ac0232eb67a3ca2d7a9b`,
  digest
  `sha256:900e0a4fd4e284003e7a80c40d066f585266bc1904bcf6b3df0061300817e61e`.

Fresh Monaco release-I/O evidence under LDC 1.41.0, Ubuntu 24.04,
release/allAtOnce:

| Operation | v0.2.0 release-branch p50 | v0.3.0 stabilization p50 |
| --- | ---: | ---: |
| semantic PBF write | 104.310 ms | **83.989 ms** |
| OSM XML write | 211.524 ms | **172.995 ms** |
| materializing OSM XML read | 772.839 ms | **650.615 ms** |

The input again contained 41,703 Nodes, 6,249 Ways and 348 Relations.
Generated sizes remained 2,496,211 bytes for semantic PBF and 11,584,269
bytes for OSM XML, with `semantic_parity=pass`.

These cross-run timing differences are observations on GitHub-hosted runners,
not causal performance claims. M11/M12 do not modify the measured PBF/XML hot
paths.

The final promotion candidate was
`db8b3fc9df5a61ec85ebbca4f56607d5af7710d4`. On that exact head:

- Release Gate 41915533901 — PASS across all six release compilers, metadata
  and Monaco I/O;
- PBF Round-trip Qualification 41915532742 — PASS;
- M6 Store Qualification 41915532416 — PASS;
- release PR #122 repeated the full main-target Release Gate as run
  41916134443 — PASS before merge.

The API freeze removes the v0.2-only ambiguous
`UploadResultEntry.action` shape guess and freezes request-aware `effectFor`
as the supported semantic classifier. No further public API change was admitted
after that checkpoint.

### v0.3.0 publication

Release PR #122 promoted the qualified candidate with a merge commit:

- `main` release commit:
  `99c5ffcb5e77f3ec48f296e9e690849190e57c40`;
- annotated tag object:
  `f593443c39843a559578f259fe49de3909c0b791`;
- tag `v0.3.0` resolves exactly to the release commit above;
- Publish release run 41917670146 — PASS;
- post-promotion Main Release Gate 41917670239 — PASS across all six compiler
  jobs, metadata and Monaco I/O;
- release archive: `osm-d-0.3.0.tar.gz`, 352,599 bytes;
- published archive digest:
  `sha256:6219cd21d5b0109a4f3c3a1716c3524b152697577272da2d7f8d460f58b80288`;
- checksum asset: `osm-d-0.3.0.tar.gz.sha256`, 85 bytes, asset digest
  `sha256:aa9feaa001199b13d56ae91004fba08c3e03e249544a47a34dbe85b613d1c160`.

The release state was forward-integrated by PR #123:

- `develop` merge commit:
  `8a0ea3eb6d9b6f21b927b02ad380ac3fd62494f2`;
- PR Fast CI 41918531765 — DMD 2.111.0 PASS, LDC 1.41.0 PASS;
- PR M6 Store Qualification 41918531517 — PASS.

The automated final release tag is annotated but unsigned. Signed-tag
automation remains separately tracked by #105 rather than being silently
claimed here.

## Historical v0.2 baseline

**v0.2 feature-freeze date:** 2026-11-04  
**v0.2 feature-freeze commit:** `fab28b1085138531ad07d95a48ad010d8300383e`

v0.2 was primarily a consumer-API and editable-store workflow release, not a
parser algorithm rewrite. Evidence is split between unchanged v0.1
performance/reference baselines and v0.2-specific requalification of the
changed API/store surface.

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

## v0.2.1 hotfix publication record

The conditional-delete diffResult correctness hotfix was released on
2026-11-04 without changing the v0.2.x compatibility line.

- hotfix source commit:
  `7c2a61048559929d5bbc3b7459232f5d4dd9d56f`;
- release PR: #107;
- `main` release merge:
  `7bd630831d53758fdad472117056c51fe983fbd2`;
- annotated tag object:
  `89bfa991d80e54df6e8cca6d0edc9d4cb03b3a27`;
- tag `v0.2.1` resolves exactly to the release merge above;
- hotfix branch Release Gate 41874141587 — PASS;
- release-PR Release Gate 41874638857 — PASS;
- Publish release 41875263245 — PASS;
- post-promotion Main Release Gate 41875263258 — PASS;
- release archive: `osm-d-0.2.1.tar.gz`, 327,676 bytes;
- published archive digest:
  `sha256:99d1450c5cb674360235895181c4fc5066714297eb191dad1f2be9cc8f18dbf0`;
- checksum asset: `osm-d-0.2.1.tar.gz.sha256`.

The patch corrects request-context interpretation of conditional
`delete if-unused` diffResult entries. It does not alter the compiler floor,
platform qualification, store representation or parser performance baseline.

## Supported toolchain and platform

Source-compatibility floor:

- D frontend 2.111;
- DUB 1.40.0.

Release compiler matrix:

- DMD 2.111.0, 2.112.1, 2.113.0;
- LDC 1.41.0, 1.42.0, 1.43.0.

The v0.3.0 release gate is Ubuntu 24.04 x86_64. Other platforms are not
claimed as release-qualified by this baseline.

LDC 1.41.0 remains the primary release-performance compiler.

The supported source API and direct-import boundary are defined in
`API_STABILITY.md`; v0.1 -> v0.2 and v0.2 -> v0.3 migration are documented
in `API_V0_2.md` and `API_V0_3.md`.

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
