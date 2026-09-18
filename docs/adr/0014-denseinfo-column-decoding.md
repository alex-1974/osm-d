# ADR 0014: DenseInfo column decoding

- Status: Accepted
- Date: 2026-09-12

## Context

OSMPBF `DenseInfo` stores node metadata column-wise. The six fields are
independently optional: version and visible are direct values; timestamp,
changeset, uid, and user string-table ID are delta coded. All fields are
packable repeated protobuf scalars and therefore legal readers must accept
both packed and unpacked wire representation.

The project integrity contract forbids emitting a valid-looking node prefix
before a later metadata error is discovered. At the same time, missing
metadata columns must not be fabricated into zero/default values because
absence is semantically relevant. In particular, interpretation of an absent
`visible` value depends on the `HistoricalInformation` header feature and
belongs above the PBF column decoder.

## Decision

DenseInfo is decoded in a separate allocation-free module.

Before the first DenseNode sink call, `validateDenseInfo` rescans all merged
DenseNodes/DenseInfo occurrences and:

1. accepts packed and unpacked scalar representation;
2. treats each of the six metadata columns as independently optional;
3. requires every *present* column to contain exactly one value per dense
   node;
4. performs checked delta accumulation for timestamp, changeset, uid and
   user_sid;
5. requires cumulative uid values to remain representable by the schema's
   int32 uid type;
6. validates every cumulative user_sid against the already indexed
   StringTable;
7. checks exact timestamp scaling by `date_granularity` for signed-64-bit
   overflow.

After successful preflight, `DenseInfoNodeCursor` produces one
`DenseInfoView` per node. Each value has an explicit `has*` flag. Username
bytes are borrowed from the StringTable; no strings or metadata arrays are
materialized.

`timestampValue` preserves the exact cumulative PBF timestamp-grid value and
`timestampMillis` exposes its exact checked product with
`date_granularity`.

No semantic default is applied for an absent `visible` column in this layer.
A later layer with HeaderBlock capability context decides the
`HistoricalInformation` default.

## Rejected alternatives

### Require all six DenseInfo columns

Rejected. Writers can independently select which metadata attributes to
store. Requiring all columns would reject valid metadata subsets.

### Allow short present columns and default the remaining nodes

Rejected for the high-integrity core. Once a column is present, a shorter
column has no explicit per-node presence bitmap and therefore makes positional
association dependent on an implicit recovery rule. osm-d fails closed instead
of inventing tail defaults.

### Decode metadata only while emitting nodes

Rejected. A malformed late user_sid or delta overflow could otherwise be
found after an earlier node prefix had already reached the sink.

### Materialize metadata arrays

Rejected. DenseInfo is naturally streamable, and materialization would add
per-block memory traffic to the hot path without improving integrity.

## Consequences

- DenseNodeView now contains a `DenseInfoView` alongside coordinates and tags.
- Metadata errors are discovered before the first node is emitted.
- Packed/unpacked compatibility is preserved for every DenseInfo column.
- Missing metadata remains explicitly missing.
- DenseInfo adds a preflight pass only when the group actually contains a
  DenseInfo message; metadata-free DenseNodes retain a cheap early exit.
- Performance impact can be measured independently by extending the existing
  DenseNodes benchmark after this correctness slice lands.
