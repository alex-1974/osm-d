# ADR 0001: Loss-aware OSM handling is the primary invariant

- Status: Accepted
- Date: 2026-09-12

## Context

OSM editors and conversion tools can corrupt data by silently dropping fields,
normalizing structures, confusing incomplete extracts with complete objects,
or rewriting an input format that contains information their internal model
cannot represent.

`osm-d` is intended both for an editor and as a standalone ecosystem library.
Its default behavior therefore must be safe for data it did not create.

## Decision

The library uses a loss-aware architecture:

- parsing does not imply semantic validity;
- a raw representation can retain data not representable by the validated OSM
  model;
- validation is explicit and layered;
- unknown information is preserved or a rewrite fails;
- implicit repair and normalization are forbidden in codec layers;
- file replacement is transactional rather than in-place;
- upload construction requires complete changed objects derived from a known
  baseline.

## Consequences

Some APIs are more explicit than a convenience-first parser. There may be both
raw and validated representations and multiple capability states. This cost is
accepted because silent loss is worse than rejecting an operation.
