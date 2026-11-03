# Editor interoperability fixtures

These fixtures are **independently authored osm-d compatibility fixtures**.
They are not copied from JOSM or iD repositories and are not claimed to be
byte-for-byte exports from either editor.

Their purpose is to exercise the interchange contracts that osm-d supports and
that are characteristic of those editors:

- `josm-supported.osm`: ordinary OSM 0.6 XML with
  `generator="JOSM"`, `upload="never"`, signed local IDs, metadata,
  ordered Way references and ordered Relation members;
- `josm-supported.osc`: JOSM-compatible osmChange create/modify/delete
  structure, explicit changeset/version metadata, negative local IDs and
  `if-unused` deletion policy;
- `id-compatible.osc`: iD-compatible upload ordering with create
  Node -> Way -> Relation dependencies, modify Node -> Way -> Relation, and
  delete Relation -> Way -> Node.

The generator attributes are fixture input data used to verify that producer
metadata does not alter OSM semantics. They are not provenance claims.

Qualification is semantic, not lexical. Whitespace, quote style, attribute
order, action-section grouping and the writer's generator string may differ
after serialization. IDs, versions, visibility, changesets, tags, coordinates,
Way reference order, Relation member order/roles, operation order and explicit
delete policy must remain semantically equivalent.

The osmChange writer has an additional independent interoperability gate:
CI generates an .osc with osm-d and requires Ubuntu's osmium-tool/libosmium to
parse the result successfully.

A literal fixture produced by executing JOSM itself is intentionally not
asserted by this directory. If such provenance is required as a release claim,
it must be generated and recorded explicitly rather than inferred from
compatible XML shape.
