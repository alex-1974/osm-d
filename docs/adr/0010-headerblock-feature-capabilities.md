# ADR 0010: HeaderBlock decoding and feature capabilities

- Status: Accepted
- Date: 2026-09-12

## Context

OSMPBF `HeaderBlock` combines ordinary document metadata with two feature lists.
A reader must reject a file when it does not understand a required feature, but
unknown optional features do not prevent read-only interpretation. At the same
time, `d-osm` is implementing PBF incrementally: decoding a HeaderBlock must not
prematurely claim support for DenseNodes, history semantics, or LocationsOnWays
before the corresponding PrimitiveBlock paths exist.

The protobuf schema also permits field reordering and duplication. Singular
scalar/string fields use last-one-wins semantics, while repeated occurrences of
a singular embedded message are merged. HeaderBBox coordinates are `sint64`
nanodegrees and therefore have an exact integer representation.

## Decision

`d-osm` separates three concerns:

1. `decodeHeaderBlock` performs structural protobuf decoding only. It is
   allocation-free, keeps the complete serialized HeaderBlock as raw bytes,
   exposes strings as borrowed bytes, merges repeated HeaderBBox occurrences,
   and retains bbox coordinates as exact signed nanodegrees.
2. Required and optional feature strings are exposed lazily in original wire
   order through allocation-free ranges rather than materialized arrays.
3. `validateRequiredFeatures` receives an explicit `HeaderFeatureSupport`
   policy supplied by the eventual reader configuration. Unknown required
   features, and known semantic features not enabled by that policy, are
   rejected and the first offending raw feature is reported. Unknown optional
   features are recorded but do not block read-only interpretation.

No HeaderBlock string is repaired or normalized. Raw bytes remain authoritative
for later preservation/rewrite decisions.

## Consequences

- Header parsing can be completed before PrimitiveBlock support without lying
  about file-level capabilities.
- Required-feature rejection is fail-closed and identifies the first offending
  declaration.
- Unknown optional declarations remain visible to later rewrite policy.
- HeaderBBox precision is never degraded through floating point.
- Feature ranges rescan a small header message instead of allocating; this is
  intentionally different from the large PrimitiveBlock hot path.
- A later full-file reader must additionally enforce document-level rules such
  as OSMHeader ordering and any required schema presence policy.
