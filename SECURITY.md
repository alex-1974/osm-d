# Security

OSM files are untrusted input. Parser safety is therefore part of the security
model, not only a correctness concern.

## Threat model

The library must defend against inputs intended to trigger:

- out-of-bounds reads/writes;
- integer overflow or underflow;
- oversized allocations;
- decompression bombs;
- pathological nesting/field counts;
- malformed or unterminated varints;
- invalid length-delimited fields;
- invalid StringTable indices;
- inconsistent PBF parallel arrays;
- excessive CPU consumption from malformed structures.

## Rules

- Validate lengths before pointer advancement or allocation.
- Apply format resource limits before decompression/allocation.
- Use checked arithmetic for offsets, sizes, deltas and coordinates.
- Bound queues and temporary memory.
- Keep unsafe pointer code small and auditable.
- Fuzz low-level wire and format boundaries.
- Do not recover from malformed input by inventing OSM data.

## Reporting

Please report suspected security issues privately to the project maintainer
rather than opening a public exploit issue before a fix is available.
