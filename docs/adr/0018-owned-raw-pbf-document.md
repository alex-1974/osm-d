# ADR 0018: M4 separates owned semantics, raw preservation, and PBF document state

- Status: Accepted
- Date: 2026-11-03
- Related: #53, #54, #55, #56

## Context

The Phase-3 reader exposes borrowed semantic views whose storage belongs to the
input PBF buffer or reader workspace. M4 needs durable editable state and must
also retain input that the semantic model cannot represent without silently
dropping it.

Making the ordinary OSM model carry protobuf field numbers, StringTable IDs,
unknown wire fields, Blob compression details, or original PBF message order
would couple every future codec and store to one source format.

Conversely, keeping only semantic elements would make a read/modify/write cycle
unable to prove that unknown source content was preserved.

## Decision

M4 uses three explicit layers.

### 1. `osm.model.owned`: format-independent durable semantics

The owned model contains Nodes, Ways, Relations, ordered tags, ordered Way node
references, ordered Relation members, exact nanodegree locations and explicit
metadata presence.

Exact string-like values are copied into immutable byte storage. Mutable arrays
use ordinary D dynamic-array ownership/copy semantics. `deepCopy` is provided
for callers that need an independently mutable snapshot.

The owned model contains no PBF field numbers, StringTable IDs, packed/delta
encoding state, block offsets, compression state, or unknown protobuf payload.

### 2. `osm.raw.pbf`: exact source preservation

The raw layer can own the exact original file bytes independently of whether the
ordinary semantic model understands them.

A preservation reason records the first known class of source content that
prevents safe semantic rewrite. Exact-source reproduction remains a separate
operation.

### 3. `osm.io.pbf.document`: codec-specific bridge

`PbfDocument` combines:

- a format-independent `OwnedDataset`;
- known HeaderBlock semantics needed by a PBF writer;
- PBF raw preservation state.

This is the read/modify/write boundary. It is intentionally PBF-specific; the
owned model is not.

## Rewrite rule

Semantic rewrite is allowed only when the preservation scan has no known
unrepresented source content. If unknown/unsupported preserved content exists,
the writer fails explicitly instead of dropping it.

Exact-source reproduction is distinct from semantic rewrite. It reproduces the
captured source bytes and does not claim to serialize current semantic edits.

## Known representation normalization

A successful semantic rewrite preserves OSM meaning, exact coordinates,
metadata presence/value, tag/reference/member order and HeaderBlock semantics.
It may choose a different legal protobuf representation, StringTable layout,
block grouping or compression. Byte-identical reproduction is guaranteed only
by the exact-source path.

## Consequences

- future XML/osmChange codecs can reuse the owned model without PBF leakage;
- raw source data remains available when semantics are incomplete;
- semantic edits cannot silently erase unknown PBF content;
- format round-trip and semantic round-trip are separate explicit contracts.
