# Technical References

This file records the primary specifications, canonical schemas and comparison
implementations used by `d-osm`. `SPEC_MATRIX.md` converts these references into
concrete design decisions and tests.

Last verification pass: **2026-09-12**.

## Source hierarchy

Use evidence in this order when behavior is disputed:

1. canonical schema / normative protocol documentation;
2. current OSM Editing API documentation and observed server contract;
3. documented real-world format variants;
4. multiple independent established implementations;
5. `d-osm` behavior.

A reference implementation is evidence, never the specification.

---

## Normative and canonical sources

### N1 — OSM Editing API v0.6

https://wiki.openstreetmap.org/wiki/API_v0.6

Current editing API contract. Relevant topics include:

- optimistic locking and version numbers;
- complete-object update semantics;
- diff upload transactionality;
- placeholder/dependency restrictions;
- server capabilities and dynamic limits;
- partial relation closure in bbox map responses;
- internal-error responses that may still return HTTP 200 and must be discarded.

The wiki currently redirects/canonicalizes through the `Api06` title on some
requests. Record a permalink/revision ID in benchmark/release evidence when a
specific wording is relied upon.

### N2 — OSM elements / data model

https://wiki.openstreetmap.org/wiki/Elements
https://wiki.openstreetmap.org/wiki/Data_model

Relevant topics:

- nodes, ways and relations;
- ordered way refs and relation membership semantics;
- tag uniqueness and current string limits;
- legitimate duplicate relation membership depending on relation type.

### N3 — OSM XML

https://wiki.openstreetmap.org/wiki/OSM_XML

Important because OSM XML is not a single byte-canonical schema. Documents
real-world assumptions and variants, including negative editor IDs, absent
blocks, unsorted IDs, optional metadata and JOSM-specific behavior.

The historical DTD/XSD attempts are useful supporting material but are not the
ultimate source of truth:

https://wiki.openstreetmap.org/wiki/API_v0.6/DTD

### N4 — OsmChange

https://wiki.openstreetmap.org/wiki/OsmChange

Relevant topics:

- `create`, `modify`, `delete` groups;
- whole-object change semantics;
- negative placeholders;
- required object content for modifications and deletions.

API-specific upload constraints must additionally be checked against N1.

### N5 — canonical OSM PBF semantic schema

Repository:
https://github.com/openstreetmap/OSM-binary

Master schema:
https://github.com/openstreetmap/OSM-binary/blob/master/osmpbf/osmformat.proto

Raw form:
https://raw.githubusercontent.com/openstreetmap/OSM-binary/master/osmpbf/osmformat.proto

This is the canonical low-level source for:

- HeaderBlock features;
- PrimitiveBlock and PrimitiveGroup;
- StringTable;
- coordinate granularity and offsets;
- Node/DenseNodes/DenseInfo;
- Way refs and `LocationsOnWays`;
- Relation parallel member arrays;
- historical `visible` semantics.

### N6 — canonical OSM PBF storage schema

https://github.com/openstreetmap/OSM-binary/blob/master/osmpbf/fileformat.proto

Raw form:
https://raw.githubusercontent.com/openstreetmap/OSM-binary/master/osmpbf/fileformat.proto

Canonical definitions for `Blob` and `BlobHeader`, including current compression
fields.

### N7 — OSM PBF format documentation

https://wiki.openstreetmap.org/wiki/PBF

Complements the `.proto` files with framing and compatibility rules, including:

- 4-byte network-order BlobHeader length;
- raw/zlib mandatory interoperability;
- BlobHeader and uncompressed Blob size limits;
- required vs optional feature handling;
- handling of unknown FileBlock types;
- `LocationsOnWays` constraints.

When wiki prose and `.proto` disagree about message structure, investigate and
record the discrepancy rather than silently choosing one.

### N8 — Protocol Buffers binary encoding

https://protobuf.dev/programming-guides/encoding/

Mandatory wire-level reference. Particularly important rules:

- field order is not guaranteed;
- repeated values preserve logical order;
- packable repeated fields must be accepted packed or unpacked;
- multiple packed occurrences concatenate;
- singular scalar duplicate fields follow last-one-wins semantics;
- unknown fields are skippable by wire type.

Also useful for proto2 schema semantics:

https://protobuf.dev/programming-guides/proto2/

---

## Reference implementations

### R1/R2 — JOSM

Repository:
https://github.com/JOSM/josm

Key current source files:

- `src/org/openstreetmap/josm/io/AbstractReader.java`
- `src/org/openstreetmap/josm/io/OsmReader.java`
- `src/org/openstreetmap/josm/io/OsmWriter.java`
- `src/org/openstreetmap/josm/io/OsmChangeBuilder.java`

Why it matters:

- mature desktop editor semantics;
- incomplete referenced primitives;
- distinction between missing positive/server references and missing
  negative/local references;
- XML parsing/writing and upload workflows.

Important limitation as a lossless oracle: JOSM's semantic model/writer
normalizes data. Current writer behavior includes sorting primitives by ID,
sorting tags by key and skipping incomplete primitives. `d-osm` must not copy
those behaviors into its loss-aware raw layer.

### R3/R4/R5 — iD

Repository:
https://github.com/openstreetmap/iD

Architecture:
https://github.com/openstreetmap/iD/blob/develop/ARCHITECTURE.md

Relevant current source:

- `modules/osm/abstract-entity.ts`
- `modules/osm/changeset.ts`
- `modules/services/osm.js`
- `modules/validations/osm_api_limits.ts`

Why it matters:

- immutable entities/persistent graph design;
- baseline/current difference model;
- type-prefixed internal identity;
- dependency-aware OsmChange creation;
- API capability-derived limits.

Current `osmChangeJXON` behavior is useful evidence: create is emitted
node->way->relation with new relation dependency sorting; modify is
node->way->relation; delete is relation->way->node with `if-unused=true`.
These are editor policies, not generic parser requirements.

### R6 — libosmium / osmium-tool / protozero

libosmium:
https://github.com/osmcode/libosmium

osmium-tool:
https://github.com/osmcode/osmium-tool

manual:
https://osmcode.org/libosmium/manual.html

protozero:
https://github.com/mapbox/protozero

Why it matters:

- primary native performance and streaming reference;
- compact/movable buffers;
- PBF block processing;
- schema-specialized, low-allocation protobuf decoding;
- fixed-point coordinate representation.

libosmium is a benchmark/reference implementation, not a definition of
correctness.

### R7 — packed/unpacked regression evidence

libosmium issue #389:
https://github.com/osmcode/libosmium/issues/389

The 2025 issue documents a legal protobuf encoding produced by protobuf-net in
which a single-element repeated field was written unpacked. libosmium 2.20.0
skipped it and lost a tag, while JOSM read the same file. This directly proves
that real-world compatibility requires the full protobuf packed/unpacked rule,
not only the encoding usually produced by OSM tooling.

libosmium v2.23.0 release notes record the corresponding fix:
https://github.com/osmcode/libosmium/releases/tag/v2.23.0

This fixture is mandatory for `d-osm` regression testing.

---

## Additional performance references

These are useful for performance methodology and architecture exploration, not
for correctness decisions.

### fast-osmpbf

https://github.com/quodestdubitandum/fast-osmpbf

Specialized high-throughput Rust PBF implementation. Any numeric comparison
must reproduce an equivalent workload on identical hardware.

### Imposm3

https://github.com/omniscale/imposm3

Useful for parallel OSM ingestion and compact/random-access cache design.

### osm2pgsql

https://github.com/openstreetmap/osm2pgsql
https://osm2pgsql.org/doc/manual.html

Useful large-scale system reference, especially for storage/cache behavior.
It is not a fair pure parser-throughput comparator when database and geometry
work are included.

---

## Evidence recording policy

For every compatibility or benchmark claim that can change with upstream code,
record at least:

- source URL/repository;
- branch/tag/commit when applicable;
- verification date;
- exact fixture/hash for data-dependent findings;
- whether the source is normative or merely observed implementation behavior.

For GitHub source evidence used to justify a permanent design decision, prefer
pinning the observed commit SHA in an ADR or regression-test comment rather
than relying only on a moving `master`/`develop` URL.

## Conflict policy

If sources disagree:

1. reproduce the input;
2. determine whether the disagreement is schema, API policy, producer variant,
   implementation bug or deliberate editor normalization;
3. add a fixture;
4. record the resolution in `SPEC_MATRIX.md`;
5. add/update an ADR if public semantics or architecture change.

Do not resolve disagreement by majority vote between implementations.
