# ADR 0026: parse OSM API diffResult as raw upload-result semantics

- Status: Accepted
- Date: 2026-11-04
- Related: #114, #111, #112, #113
- Supersedes: none
- References:
  - OSM API 0.6 diff upload response
  - ADR 0019 transport byte-resource I/O
  - ADR 0020 format-neutral change semantics
  - ADR 0025 editable store change/upload bridge

## Context

M9 established the format-neutral `UploadResult` model and store
reconciliation, but deliberately stopped before HTTP/network concerns. A real
OSM editor still needs to turn the Editing API's XML `diffResult` response
into that model.

The response is small compared with PBF datasets but is still external,
untrusted XML. osm-d already has a bounded transport-d/dxml XML boundary for
ordinary OSM XML and osmChange.

Current OSM server behavior also demonstrates that response shape is not a
safe action discriminator. Conditional delete-if-unused can have the same raw
old/new ID/version shape as modify, and placeholder reuse can repeat one
type+oldId several times.

## Decision

### Add a focused upload-result codec

Add a new internal codec family under `osm.io.upload` and a consumer facade:

```d
import osm.upload;
```

The codec parses only the successful diff-upload XML response. It does not send
HTTP requests, authenticate users, open/close changesets or implement retries.

### Preserve raw result order and fields

Each Node/Way/Relation element becomes one `UploadResultEntry` in source
order.

The parser validates representation shape but does not infer
create/modify/delete. Semantic interpretation remains
request-context-aware through `UploadResultEntry.effectFor`.

Duplicate type+oldId entries are valid and preserved.

### Reuse the existing XML/transport boundary

Use:

`ByteSource -> XmlCharRange -> dxml`

The parser shares encoding preparation and byte-resource behavior with the
existing OSM XML/osmChange readers. No additional XML dependency or generic I/O
abstraction is introduced.

### Keep the package root slim

The new reader is not re-exported from `import osm;`. Consumers explicitly
opt into the Editing API response codec with `import osm.upload;`.

This is additive work for the next minor release and does not alter the frozen
v0.2.x supported facade set.

### Fail closed

Unknown root/entry attributes and child content are rejected. API version 0.6
is required. Numeric IDs/versions and paired new-ID/new-version presence are
validated. Parsing has an explicit entry limit.

## Consequences

The reusable semantic chain becomes complete without network coupling:

`store -> changes -> osmChange -> HTTP boundary -> diffResult XML -> UploadResult -> store`

Applications can provide any HTTP/OAuth implementation that yields a
transport-d `ByteSource` for the successful response.

Server-specific response ambiguities stay out of parser control flow: the
codec preserves evidence, while the existing model applies request context.

The new parser adds another narrow `@trusted` dxml orchestration boundary,
matching the existing XML/osmChange readers; no parser entity or borrowed dxml
range escapes the call.

## Alternatives rejected

### Parse diffResult in the application

Rejected because the response is an OSM Editing API wire format with reusable
OSM semantics, not Dunia-specific state.

### Add an HTTP OSM client to osm-d

Rejected because authentication, connection/retry policy and changeset
lifecycle are separate application/service concerns and would broaden the
library responsibility substantially.

### Infer action from response shape

Rejected because current server behavior makes that inference incorrect for
conditional deletion.

### Key results by type+oldId

Rejected because valid placeholder reuse produces repeated identities.
