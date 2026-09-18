# ADR 0003: Separate borrowed views from owned OSM values

- Status: Accepted
- Date: 2026-09-12

## Context

Materializing every parsed node, tag, way reference and relation member into
individually owned heap objects is expensive for city and country extracts.
Applications nevertheless sometimes need durable objects.

## Decision

`osm-d` exposes two explicit lifetimes:

- borrowed `*View` values that may reference a current input/decompression
  block, StringTable or worker arena;
- owned model values created only through explicit copy/materialization.

A third path allows direct decoding into a compact long-lived store without an
intermediate owned object per element.

Borrowed values are designed to work with D `scope` semantics.

## Consequences

Streaming users avoid unnecessary allocation. Applications that retain data
must choose ownership explicitly. API naming and documentation must make view
lifetimes difficult to misunderstand.
