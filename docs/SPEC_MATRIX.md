# OSM Specification and Real-World Compatibility Matrix

This document is the working map from normative format/API requirements to
real-world producer/consumer behavior and `d-osm` tests.

The hierarchy for resolving uncertainty is:

1. normative specification or canonical schema;
2. observed OSM server behavior;
3. documented real-world producer behavior;
4. multiple established implementations;
5. `d-osm` behavior.

No single reference implementation defines correctness.

## Primary sources

- OSM API 0.6 documentation
- OSM data model documentation
- `openstreetmap/OSM-binary` canonical `.proto` files
- Protocol Buffers wire-format documentation
- osmChange documentation

## Reference implementations

- JOSM
- iD
- libosmium / osmium-tool
- additional high-performance PBF implementations for performance-specific
  comparisons

## Matrix

| Area | Requirement/question | Normative source checked | JOSM | iD | libosmium | d-osm test |
| --- | --- | --- | --- | --- | --- | --- |
| IDs | signed/local negative IDs | TODO | TODO | TODO | TODO | TODO |
| IDs | node/way/relation ID spaces are distinct | TODO | TODO | TODO | TODO | TODO |
| Tags | duplicate keys | TODO | TODO | TODO | TODO | TODO |
| Tags | ordering and round-trip policy | TODO | TODO | TODO | TODO | TODO |
| Ways | node-ref ordering | TODO | TODO | TODO | TODO | TODO |
| Relations | member ordering | TODO | TODO | TODO | TODO | TODO |
| Relations | duplicate members | TODO | TODO | TODO | TODO | TODO |
| Partial data | unresolved positive references | TODO | TODO | TODO | TODO | TODO |
| Partial data | unresolved local/negative references | TODO | TODO | TODO | TODO | TODO |
| Coordinates | precision and valid bounds | TODO | TODO | TODO | TODO | TODO |
| Metadata | missing/omitted metadata | TODO | TODO | TODO | TODO | TODO |
| PBF | required/optional features | TODO | TODO | n/a | TODO | TODO |
| PBF | packed and unpacked repeated scalars | TODO | TODO | n/a | TODO | TODO |
| PBF | repeated field segmentation | TODO | TODO | n/a | TODO | TODO |
| PBF | DenseNodes array consistency | TODO | TODO | n/a | TODO | TODO |
| PBF | HistoricalInformation / visible | TODO | TODO | n/a | TODO | TODO |
| PBF | LocationsOnWays | TODO | TODO | n/a | TODO | TODO |
| XML | unknown attributes/elements | TODO | TODO | TODO | TODO | TODO |
| osmChange | create/modify/delete ordering | TODO | TODO | TODO | TODO | TODO |
| API | modify is complete-object replacement | TODO | TODO | TODO | TODO | TODO |
| API | capabilities-derived limits | TODO | TODO | TODO | n/a | TODO |

## Rule for implementation

No behavior moves from `TODO` to an implicit assumption. It must be either
verified and tested or represented explicitly as unsupported/unknown.
