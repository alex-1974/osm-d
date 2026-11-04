# ADR 0027: project Editing API capabilities into validation policy

- Status: Accepted
- Date: 2026-11-04
- Related: #119, #116, #117, #118
- References:
  - OSM API 0.6 capabilities endpoint
  - current OpenStreetMap Rails capabilities builder/tests
  - ADR 0019 transport byte-resource I/O
  - ADR 0026 diffResult codec

## Context

`validateUploadChanges` already accepts a `CapabilityProfile` because
Way-node, Relation-member and Changeset-element limits are target-server policy,
not format constants.

Until M12, callers had to populate that profile themselves even though the OSM
Editing API publishes the current values through its capabilities endpoint.

The endpoint contains substantially more information than osm-d upload
validation needs, including map/Notes/GPX query policy and imagery blacklist
rules. It also evolves independently of osm-d.

## Decision

### Add a focused capabilities facade

Add:

```d
import osm.capabilities;
```

The facade reads the XML capabilities response and returns an
editing/upload-relevant projection.

### Reuse CapabilityProfile

Do not create duplicate Way/Relation/Changeset limit types. The parsed
projection owns one existing `CapabilityProfile`, exposed through
`validationProfile`.

### Preserve useful editing state

Retain API version range, timeout and database/API/GPX service state because
they are meaningful to an editing consumer even though only the size limits
feed semantic upload validation.

No network action is inferred from these values.

### Projection, not accidental full model

Map/Notes/GPX query limits and imagery policy are deliberately outside this
model. They and future unrelated siblings are skipped under an explicit bounded
forward-compatibility rule.

Projected fields remain fail-closed: missing/invalid required limits, duplicate
projected elements, bad service-state values and unsupported root API version
fail explicitly.

### Reuse the XML boundary

Use the existing:

`ByteSource -> XmlCharRange -> dxml`

No HTTP client, JSON dependency or second XML stack is introduced.

## Consequences

Consumers can discover current server upload limits and feed them directly into
the existing validator without hardcoded examples.

The public model stays narrow enough to remain an OSM data/editing library
rather than becoming a general server administration API.

The projection parser remains robust when the capabilities endpoint adds an
unrelated field.

JSON capabilities remain optional future work; semantic policy stays one model.

## Alternatives rejected

### Hardcode current openstreetmap.org limits

Rejected because the endpoint explicitly defines them as mutable server policy.

### Model every capabilities field

Rejected because most fields are unrelated to osm-d's data/editing
responsibility and would create an unnecessarily broad compatibility surface.

### Reject every unknown sibling

Rejected because unrelated capability expansion should not break discovery of
the upload limits we intentionally consume.

### Add HTTP/OAuth handling

Rejected because transport/session/account policy remains a separate consumer
responsibility.
