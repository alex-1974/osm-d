# v0.2 -> v0.3 API migration

**Status:** v0.3.0 release migration guide  
**Compatibility contract:** `API_STABILITY.md` defines the frozen v0.3.x
source contract.

v0.3 keeps the v0.2 semantic/store/PBF surface and adds two focused Editing API
response facades. One deliberately misleading v0.2 compatibility property is
removed before the v0.3 API freeze.

## New focused upload facade

Use:

```d
import osm.upload;
```

for parsing the XML `diffResult` returned by an OSM API diff upload.

The facade exposes:

- `UploadResult`, `UploadResultEntry`, `UploadResultEffect`;
- `UploadResultDocumentInfo`, `UploadResultDocument`;
- `UploadResultReader`;
- `UploadResultReadError`, `UploadResultReadStatus`,
  `UploadResultReadOptions`, `UploadResultReadSummary`;
- `readUploadResult`;
- `readUploadResultDocument`.

The package root `import osm;` stays unchanged.

## Typical workflow

```d
import osm;
import osm.osmchange;
import osm.upload;
import osm.validate;

OwnedChangeSequence changes;
StoreStatus storeStatus;

if (!store.collectChanges(changes, storeStatus))
    return;

if (!changes.setChangeset(openChangesetId))
    return;

// validateUploadChanges(...)
// OsmChangeWriter.writeChanges(...)
// application sends bytes via its own HTTP/OAuth layer

UploadResult result;
UploadResultReadStatus readStatus;

if (!readUploadResult(responseSource, result, readStatus))
    return;

if (!store.applyUploadResult(changes, result, storeStatus))
    return;
```

The network boundary is intentionally external. osm-d neither opens/closes the
changeset nor chooses HTTP, authentication, retry or account policy.

## Raw result semantics

The parser preserves source order and the raw `old_id`, `new_id` and
`new_version` fields.

It does **not** infer the originating request action from response shape.
Current OSM server behavior makes that unsafe:

- conditional `delete if-unused` may return ID/version when deletion was not
  performed;
- one negative placeholder may occur in several result entries when an upload
  creates, modifies and deletes that placeholder.

Use `UploadResultEntry.effectFor(uploadedEntry, effect)` when semantic effect
classification is required.

### Migration from the v0.2 context-free action guess

v0.2.1 retained `UploadResultEntry.action` only for patch-line source
compatibility, even though the property could not distinguish ordinary modify
from retained/already-deleted conditional delete results.

v0.3 removes that property. Replace code such as:

```d
auto action = resultEntry.action;
```

with request-aware classification:

```d
UploadResultEffect effect;
if (!resultEntry.effectFor(uploadedEntry, effect))
{
    // result cannot acknowledge this request entry
}
```

This is the only deliberate source-breaking change from the supported v0.2.x
surface.

## Bounded parsing

`UploadResultReader` uses the existing transport-d/dxml XML boundary.
`UploadResultReadOptions.maximumEntries` provides an explicit response bound;
zero selects the documented default of 100,000 entries.

Streaming callbacks preserve source order. The one-shot materializing helpers
are transactional and leave the destination at `.init` on failure.

Unknown root/entry attributes and unsupported content fail explicitly.

## v0.3 facade policy

M11 adds a new facade rather than expanding `import osm;`. Specialized
wire-format/server-response families remain opt-in and the common root stays
focused on ordinary semantic/store/PBF traversal work.

The frozen v0.3.x surface must not silently broaden `osm.upload` into an
HTTP/account client. A future network abstraction requires a separate
responsibility/API decision.


## Editing API capability discovery

M12 adds another focused facade:

```d
import osm.capabilities;
```

It projects the XML response from `GET /api/0.6/capabilities` onto the
editing/upload policy that osm-d actually consumes.

```d
EditingApiCapabilitiesDocument document;
ApiCapabilitiesReadStatus status;

if (!readEditingApiCapabilities(source, document, status))
    return;

CapabilityProfile target = document.capabilities.validationProfile;

UploadValidationIssue issue;
if (!validateUploadChanges(changes, target, issue))
    return;
```

The projection maps the server-provided maximum Way nodes, Relation members and
Changeset elements directly into the existing `CapabilityProfile`.
API minimum/maximum version, optional timeout and database/API/GPX service state
remain available for editing consumers.

This is intentionally not a full server-capability model. Map/Notes/GPX query
limits, imagery policy and future unrelated siblings are boundedly skipped
under a documented projection policy. Projected fields remain fail-closed.

The capability values are dynamic server policy. Example openstreetmap.org
values are never compiled into validation defaults.

The XML form is implemented first because it reuses osm-d's existing bounded
transport-d/dxml boundary. JSON capability support remains additive future work
only if a consumer requires it.


## Upgrade summary

For ordinary v0.2.x consumers:

1. change the DUB dependency to `~>0.3.0`;
2. no source change is required for the existing `osm`, `osm.pbf`,
   `osm.store`, `osm.compare`, `osm.xml`, `osm.osmchange` or
   `osm.validate` workflows;
3. if code used the deprecated-by-contract
   `UploadResultEntry.action` shape guess, migrate to `effectFor`;
4. use `osm.upload` when parsing successful diff-upload responses;
5. use `osm.capabilities` when discovering target-server validation limits.

HTTP/OAuth, changeset lifecycle, retry policy and application worksets remain
outside osm-d in v0.3.x.
