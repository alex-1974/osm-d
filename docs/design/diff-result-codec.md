# OSM API diffResult codec contract

Issue: #114  
Work items: #111, #112, #113  
Decision record: ADR 0026

## Purpose

The editable store already produces format-neutral upload changes and can
reconcile an authoritative `UploadResult`. M11 closes the remaining wire
boundary by parsing the XML `diffResult` returned by:

`POST /api/0.6/changeset/{id}/upload`

The codec belongs in osm-d because the response is an OSM Editing API data
format. HTTP transport, authentication, account state, changeset creation and
closing, retries and editor workflow policy remain outside osm-d.

## Primary evidence

Evidence checked on 2026-11-04:

- OSM API 0.6 documentation:
  https://wiki.openstreetmap.org/wiki/API_v0.6
- current OpenStreetMap Rails implementation:
  `openstreetmap/openstreetmap-website/lib/diff_reader.rb`
  at `066cedfff25c79ef77aa8f622461c39c6500e702`;
- current upload integration tests:
  `test/controllers/api/changesets/uploads_controller_test.rb`
  at the same commit;
- API XML root metadata implementation:
  `openstreetmap/openstreetmap-website/lib/osm.rb`
  at the same commit.

The implementation is important evidence because the Wiki's compact response
table has historically lagged details of server behavior. osm-d therefore
parses the raw response shape without inferring request action from it.

## Envelope

The root element is:

```xml
<diffResult ...>
  ...
</diffResult>
```

Current Rails responses inherit the common API XML root attributes before the
root is renamed from `osm` to `diffResult`:

- `version`;
- `generator`;
- `copyright`;
- `attribution`;
- `license`.

`version="0.6"` is required by the osm-d codec. The informational root
attributes are optional in the model but preserved when present. Unknown root
attributes fail explicitly rather than being silently discarded.

## Entries

Only `node`, `way` and `relation` entries are accepted.

`old_id` is required. `new_id` and `new_version` are either both present
or both absent.

Raw result entries deliberately do not carry an action field because the same
field shape can represent different request outcomes:

- create normally returns old placeholder ID + new ID/version;
- modify returns old ID + current ID/version;
- confirmed delete normally returns only old ID;
- conditional `delete if-unused` can return current ID/version when deletion
  was not performed;
- an already-deleted conditional request can also return current server
  ID/version.

The parser stores these fields in `UploadResultEntry`. Consumers that need
semantic operation/effect classification use
`UploadResultEntry.effectFor(uploadedEntry, effect)`.

## Ordering and duplicate identities

Entry order is preserved exactly.

The current server allows a negative placeholder to be created, modified and
deleted in one upload. Its `diffResult` therefore contains multiple entries
with the same type and `old_id`.

The codec MUST NOT deduplicate, sort or key entries by type+oldId.

This does not change the compact-store contract: `OsmStore.collectChanges`
materializes one final pending operation per store identity. Generic
`UploadResult` values remain able to represent broader valid Editing API
responses.

## Bounded parsing

The codec reuses the existing XML stack:

`transport-d ByteSource -> XmlCharRange -> dxml -> UploadResultEntry`

No second XML parser or byte-resource hierarchy is introduced.

`UploadResultReadOptions.maximumEntries` defaults to 100,000. This is
deliberately above the current Editing API changeset element limit while
bounding hostile/non-standard responses. Callers can choose a stricter bound.

The reader is streaming and source-order preserving. The one-shot
`readUploadResult` and `readUploadResultDocument` helpers are transactional:
failure leaves the destination at `.init`.

## Failure policy

The reader fails explicitly on:

- malformed XML;
- unsupported encoding;
- missing/wrong API version;
- unsupported root/child content;
- missing `old_id`;
- invalid numeric attributes;
- only one of `new_id` / `new_version`;
- invalid ID/version shape;
- entry resource-limit exhaustion;
- trailing content after the root.

No repair, action inference or silent unknown-attribute dropping occurs.

## Public API

The focused facade is:

```d
import osm.upload;
```

It exposes:

- `UploadResult`, `UploadResultEntry`, `UploadResultEffect`;
- `UploadResultDocumentInfo`, `UploadResultDocument`;
- `UploadResultReader`;
- read status/options/summary types;
- `readUploadResult`;
- `readUploadResultDocument`.

The package root `import osm;` remains unchanged. M11 is additive next-minor
work and does not modify the frozen v0.2.x facade contract.

## Qualification

Permanent tests cover:

- current Rails-style root metadata;
- create, modify and confirmed-delete shapes;
- conditional retained/already-deleted shapes through `effectFor`;
- repeated placeholder `old_id` in source order;
- empty result;
- Node/Way/Relation;
- malformed/missing/unsupported attributes and content;
- resource limit;
- external consumer compilation;
- parser -> `OsmStore.applyUploadResult` workflow.

The fixtures are independently authored from documented/server behavior; no
third-party test fixture is copied into osm-d.
