# Editing API capabilities projection

Issue: #119  
Work items: #116, #117, #118  
Decision record: ADR 0027

## Purpose

osm-d already validates an `OwnedChangeSequence` against a caller-supplied
`CapabilityProfile`. The values in that profile are server policy, not OSM
format constants.

M12 connects that validation model to the authoritative XML response from:

`GET /api/0.6/capabilities`

without making osm-d responsible for HTTP, endpoint discovery, authentication,
retry/backoff or account state.

## Evidence

Evidence checked on 2026-11-04:

- current OSM API 0.6 capabilities documentation;
- current OpenStreetMap Rails capabilities builder at
  `openstreetmap/openstreetmap-website`
  commit `066cedfff25c79ef77aa8f622461c39c6500e702`;
- current Rails capabilities controller tests at the same commit.

Current Rails XML contains:

- root version/generator/legal metadata;
- API minimum/maximum version;
- map and note area limits;
- tracepoint page size;
- maximum Way nodes;
- maximum Relation members;
- Changeset maximum elements and query limits;
- Notes query limits;
- API timeout;
- database/API/GPX service state;
- imagery blacklist policy.

The API documentation explicitly warns that actual capability values may change
at any time. osm-d therefore never hardcodes example values as validation
truth.

## Projection boundary

M12 deliberately does **not** claim a lossless/full model of every server
capability.

The editing/upload projection retains:

- root version/generator/legal metadata;
- API minimum and maximum version strings;
- `waynodes.maximum`;
- `relationmembers.maximum`;
- `changesets.maximum_elements`;
- optional API timeout;
- optional database/API/GPX service states.

The three upload-size limits are stored directly in the existing
`CapabilityProfile`.

The projection does not import these unrelated semantics into upload
validation:

- map request area;
- Notes request area/query limits;
- GPX tracepoint page size;
- Changeset query page limits;
- imagery blacklist policy.

These and future unrelated capability siblings are boundedly consumed/skipped.
This is intentional projection, not silent data loss from a purported full
capability model.

## Forward compatibility

The capabilities endpoint is explicitly extensible policy state. A parser that
rejected every new unrelated sibling would make upload validation unnecessarily
fragile.

Therefore:

- projected elements/attributes are validated strictly;
- duplicate projected elements fail;
- required projected limits/version range must be present;
- invalid projected numeric/status values fail;
- unrelated root/API subtrees and extra unrelated attributes are tolerated;
- skipped XML work is bounded by
  `ApiCapabilitiesReadOptions.maximumIgnoredXmlEvents`.

This differs intentionally from semantic OSM element codecs, where unknown
content may represent map data that cannot be silently discarded.

## Required projection

A successful materialized result requires:

- root `version="0.6"`;
- API version minimum and maximum;
- positive Way-node maximum;
- positive Relation-member maximum;
- positive Changeset-element maximum.

Timeout and service-status data are retained when present but are not required
to construct a validation profile.

## Service state

`ApiServiceState` represents exactly the current server vocabulary:

- `online`;
- `readonly`;
- `offline`;
- `unknown` only as the model's absent/.init state.

The parser rejects an unrecognized value when a projected status attribute is
present. It does not convert service state into network retry behavior.

## Public API

The focused facade is:

```d
import osm.capabilities;
```

It exposes:

- `CapabilityProfile`;
- `ApiServiceState`;
- `ApiCapabilitiesDocumentInfo`;
- `EditingApiCapabilities`;
- `EditingApiCapabilitiesDocument`;
- `ApiCapabilitiesReader`;
- read status/options/error;
- `readEditingApiCapabilities`.

The package root remains unchanged.

## Consumer flow

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

The validator's existing rule remains important: the server's
`maximum_elements` describes the complete changeset. Validation of one local
request can enforce it as an upper bound, but a caller reusing an already
populated changeset must still account for previously uploaded elements.

## JSON

The current endpoint also supports JSON. M12 intentionally implements the XML
form because osm-d already has a bounded XML stack and the consumer need is
satisfied without another public representation.

JSON support, if later justified by a consumer, is additive work and must map
to the same semantic projection rather than creating a second policy model.
