# Technical References

This list records primary specifications and important comparison
implementations. `docs/SPEC_MATRIX.md` tracks individual behavior once it has
been verified.

## OSM specifications and canonical schemas

- OSM API 0.6: https://wiki.openstreetmap.org/wiki/API_v0.6
- OSM data model: https://wiki.openstreetmap.org/wiki/Elements
- OSM PBF overview: https://wiki.openstreetmap.org/wiki/PBF_Format
- Canonical OSM-binary repository: https://github.com/openstreetmap/OSM-binary
- `osmformat.proto`: https://github.com/openstreetmap/OSM-binary/blob/master/osmpbf/osmformat.proto
- `fileformat.proto`: https://github.com/openstreetmap/OSM-binary/blob/master/osmpbf/fileformat.proto
- osmChange: https://wiki.openstreetmap.org/wiki/OsmChange
- Protocol Buffers encoding: https://protobuf.dev/programming-guides/encoding/

## Reference implementations

### libosmium / osmium-tool

- https://github.com/osmcode/libosmium
- https://github.com/osmcode/osmium-tool
- https://docs.osmcode.org/libosmium/latest/

Primary reference for high-performance native OSM processing and streaming
architecture. It is a comparison implementation, not the definition of
correctness.

### JOSM

- https://github.com/JOSM/josm

Important reference for mature desktop-editor behavior, incomplete primitives,
OSM XML handling, validation and upload workflows.

### iD

- https://github.com/openstreetmap/iD

Important reference for immutable editor entities/graphs, difference-based
editing, API limits/capabilities and upload construction.

## Performance comparisons

Additional specialized PBF readers may be added to benchmark comparisons only
when an equivalent workload can be constructed. Comparative numbers belong in
benchmark records, not in architecture assumptions.

## Evidence rule

When sources disagree, investigate the reason. Do not choose behavior by
popularity. The intended evidence order is:

1. normative/canonical specification;
2. OSM server behavior;
3. documented real-world producer behavior;
4. multiple independent implementations;
5. d-osm behavior.
