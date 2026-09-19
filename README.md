# osm-d

`osm-d` is a standalone OpenStreetMap data library for D. It is being built as
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

When this repository is used inside `d-geospatial-workspace`, shared
workspace documents are linked only into `.workspace/`. Repo-root documents
remain repository-specific. The helper `tools/link-workspace-docs.sh` manages
only `.workspace/`.

## Build

```bash
dub build
dub test
```

The reference compiler for release-performance benchmarks is LDC. DMD remains
the fast development/correctness compiler. The current pre-1.0 supported and
tested matrix is DMD 2.111.0 and LDC 1.41.0 with DMD frontend 2.111.0; see
`docs/DEVELOPMENT.md` for the compiler-support policy and canonical checks.

## Status

The first substantial PBF implementation slice is in place. Implemented
components include bounded PBF framing/decompression, HeaderBlock capability
handling, PrimitiveBlock layout and StringTable indexing, DenseNodes including
tags and DenseInfo, regular Node, Way, and Relation decoding, and reproducible
microbenchmarks for the current entity hot paths.

DenseNodes scalar hot-path research has progressed through experiments A2-A10b.
The retained A8e implementation reuses the already validated sole DenseNodes
payload for implicit-all-tagless groups, A9a removes a duplicate post-layout
DenseNodes column-length guard under the validated-layout contract, A10a uses
the completed DenseTags preflight to avoid repeating StringTable-ID semantic
validation while partitioning tags during internal emission, and A10b carries
that construction-controlled proof into `DenseTagRange` pair decoding. Public
defensive validation and `StringTableView.get()` bounds checks remain intact.
Detailed evidence and rejected alternatives are recorded in
`docs/BENCHMARKS.md`.

The format-independent borrowed `ElementView` identity contract is now in
place, and the current DenseNode, regular Node, Way, and Relation PBF views
conform to it without changing their codec-owned representations. Structural
validation, the production parallel PBF reader and public range adapter,
XML/osmChange support, and the compact editable store remain future work.

The repository was renamed from `d-osm` to `osm-d` during the coordinated
workspace reorganization on 2026-09-18. The repository and DUB package now use
the `osm-d` name.
