# ADR 0020: format-neutral OSM change semantics

- Status: Accepted
- Date: 2026-11-03
- Related: #45, #57, #58, #59, #60
- Normative references:
  - https://wiki.openstreetmap.org/wiki/Api06
  - https://wiki.openstreetmap.org/wiki/OSM_XML
  - https://wiki.openstreetmap.org/wiki/OsmChange

## Context

M5 adds ordinary OSM XML and osmChange. XML is a wire/text format, not the
library's underlying data structure. The public model must continue to describe
OSM semantics rather than XML parser tokens, element names, attributes, or a
DOM.

The OSM Editing API applies create, modify and delete to whole OSM objects.
Modify is not a tag/ref/member patch: omitted content would change the complete
resulting object. Delete is different because the API permits a minimal object
containing identity plus the required version/changeset metadata.

The ordinary OSM element metadata field `visible` is historical/state metadata.
It is not the same concept as an edit operation. A historical object with
`visible=false` therefore must not become a delete operation merely because it
is read from XML.

osmChange also permits the delete-group `if-unused` policy. Injecting that
policy implicitly would change upload behavior.

## Decision

### Shared semantic model

`OwnedNode`, `OwnedWay` and `OwnedRelation` remain the ordinary durable OSM
object model.

Changes use the format-neutral types in `osm.model.change`:

- `ChangeAction.create`;
- `ChangeAction.modify`;
- `ChangeAction.deleteObject`;
- `OwnedChangeEntry`;
- `OwnedChangeSequence`.

No public change type exposes XML tag/attribute objects or dxml parser types.

### Complete versus minimal objects

Create and modify entries carry `ChangeObjectState.complete`.

A delete entry may be:

- complete, when the source contains the prior full object; or
- `identityOnly`, when only the deletion identity/metadata is present.

This distinction prevents a minimal delete from being represented as a fake
Node at 0/0 or as an apparently complete empty Way/Relation.

Complete-object and API-upload validity are stronger properties than this
representation shape and remain the responsibility of #60.

### Metadata

ID, version, timestamp, changeset, user ID, username and visibility retain the
same meanings and independent presence flags as `OwnedMetadata`.

Operation and state are independent:

```text
ChangeAction.deleteObject    = requested operation
metadata.visible == false    = represented object state/history metadata
```

Neither one is inferred from the other.

For API upload, current v0.6 policy requires a changeset on every uploaded
element and a version on modify/delete; create does not require a version.
Username/user ID are informative and not required for upload. Those are
validation rules, not parser defaults.

### Ordering

`OwnedChangeSequence.entries` preserves semantic input order exactly.

A codec may group consecutive entries to satisfy its syntax, but must not
silently sort or dependency-reorder them. Dependency-safe API upload ordering
is an explicit higher-layer transformation.

### Conditional deletion

`deleteIfUnused` is explicit on each delete entry. A reader maps an
osmChange `<delete if-unused=...>` group to that flag on its entries. A writer
must not invent the flag.

### Unknown XML content

The ordinary semantic XML reader does not silently discard unknown attributes
or elements. Unknown content that is not explicitly represented by the
supported OSM XML contract causes an explicit unsupported-content failure.

If a future use case requires byte/lexical XML preservation of arbitrary
extensions, that requires a separate raw/preservation representation. It is not
achieved by leaking a DOM or dxml tokens into the semantic model.

Known format-level XML metadata such as the root version/generator and bounds
may be represented by the XML codec/document layer without creating
XML-specific Node/Way/Relation types.

### Streaming lifetime

dxml tokens and character ranges are codec-internal borrowed values. They must
not escape the XML parser.

A streaming XML/osmChange reader may materialize one complete owned object or
change entry at a time and hand it to the consumer. Retaining those owned
values is a consumer choice and does not require retaining the XML input or
parser buffer.

## Consequences

- XML remains an interchange format, not the internal data structure.
- PBF, XML and future codecs converge on the same owned element semantics.
- modify cannot accidentally become a partial patch representation.
- minimal deletes are representable without inventing object content.
- visibility and deletion operation remain distinct.
- osmChange conditional-delete policy is explicit.
- unknown XML extensions fail closed instead of disappearing on rewrite.
- dxml can remain a replaceable implementation dependency below the public API.
