# d-osm

`d-osm` is a standalone OpenStreetMap data library for D. It is being built as
a reusable component for a future OSM editor, but its public design is not tied
to that editor.

The library has two non-negotiable goals:

1. **Data integrity.** OSM data must never be silently dropped, repaired,
   normalized or approximated. If an operation cannot be performed without
   information loss, it must fail explicitly.
2. **Performance and scalability.** City-scale datasets must be processable in
   reasonable time and memory. Streaming, bounded memory, parallel PBF
   decoding, allocation discipline and reproducible benchmarks are part of the
   architecture from the beginning.

A third rule follows from both:

3. **Measure, do not assume.** Performance choices are benchmarked against
   strong reference implementations; compatibility choices are checked against
   specifications and real-world OSM behavior.

## Scope

Planned scope includes:

- the OSM object model: nodes, ways, relations, tags and metadata;
- streaming and owned representations;
- OSM XML;
- OSM PBF;
- osmChange;
- structural and semantic validation;
- loss-aware read/write round trips;
- compact stores for larger editable datasets;
- utilities needed by OSM tooling without pulling in editor/UI concerns.

The parser is not a renderer, GUI toolkit, spatial database or editor history
engine.

## Architecture

The core layers are deliberately separated:

```text
bytes
  -> memory / wire
  -> format codec (PBF, XML, osmChange)
  -> raw representation
  -> validation
  -> borrowed OSM views
  -> owned model or compact store
  -> application
```

The PBF hot path is push-based and allocation-controlled. D ranges are used at
public pipeline boundaries, not forced through the innermost varint/delta
loops. See `ARCHITECTURE.md` and `docs/adr/0004-streaming-api.md`.

## Project documents

- `ARCHITECTURE.md` — module boundaries and data flow
- `docs/DATA_INTEGRITY.md` — integrity contract
- `docs/PERFORMANCE.md` — performance contract and hot-path rules
- `docs/BENCHMARKS.md` — benchmark methodology
- `docs/SPEC_MATRIX.md` — specifications, real-world behavior and reference implementations
- `docs/adr/` — architecture decision records
- `ROADMAP.md` — implementation sequence

## Shared workspace context

When this repository is used inside the `d-geospatial` workspace, shared
workspace documents are linked only into `.workspace/`. Repo-root documents
remain repository-specific. The helper `tools/link-workspace-docs.sh` manages
only `.workspace/`.

## Build

```bash
dub build
dub test
```

The reference compiler for release-performance benchmarks will be LDC. DMD
remains useful for fast development cycles.

## Status

Architecture and conformance requirements are being fixed before the first
substantial codec implementation. The initial vertical slice is PBF framing ->
wire decoding -> DenseNodes -> borrowed element views -> validation ->
benchmarks.
