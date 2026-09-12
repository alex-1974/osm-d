# ADR 0006: Validation is layered and fail-closed

- Status: Accepted
- Date: 2026-09-12

## Context

"Parsed successfully" is not a sufficient statement for OSM data. A stream can
be valid protobuf but invalid PBF, valid PBF but invalid OSM, or valid OSM while
referencing elements absent from a partial extract.

## Decision

Validation is represented in separate stages:

1. wire validity;
2. format structural validity;
3. OSM element validity;
4. dataset/reference validity;
5. operation-specific validity such as uploadability.

Hot-path failures return structured non-allocating error states. Higher-level
APIs may enrich them after leaving the `@nogc` region.

No later stage assumes an earlier stage succeeded unless its type/API contract
proves that fact.

## Consequences

The library can safely handle partial extracts and diagnostic workflows without
calling them fully valid or uploadable. Tests can target each failure class
independently.
