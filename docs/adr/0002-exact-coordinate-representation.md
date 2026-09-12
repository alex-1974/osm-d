# ADR 0002: Authoritative coordinates are exact, not floating-point

- Status: Accepted
- Date: 2026-09-12

## Context

PBF stores coordinate components as signed integers combined with block
`granularity` and offsets. XML presents decimal text. Converting source data
through `double` as the authoritative representation can introduce rounding
and makes exact round-trip claims difficult to prove.

## Decision

The authoritative decode/validation path uses exact integer/fixed-point
coordinate representations and checked arithmetic.

- PBF raw values and their block parameters remain exact during decoding.
- The normalized OSM representation uses an exact fixed-point form appropriate
  to the validated OSM precision contract.
- XML raw handling can retain lexical source representation where required for
  loss-aware round trips.
- Floating-point degrees are derived convenience views for geometry and UI
  work, never the canonical round-trip source.

The exact normalized scale is part of the specification audit and must not be
silently changed once public.

## Consequences

Coordinate conversion becomes explicit and testable. Overflow checks are part
of normal decoding. Geometry algorithms may use floating point without
changing stored source coordinates.
