# Editing API protocol-client direction

Status: accepted M17 design direction from ADR 0032. This document describes
the intended consumer surface before transport-d#3 fixes the concrete generic
HTTP exchange types.

## Consumer goal

A consumer should express OSM operations in OSM terms rather than assemble
HTTP requests manually.

The focused facade is intended to be:

```d
import osm.api;
```

and the primary public type should be named around the domain, for example
`EditingApiClient`, rather than around curl, HTTP or a transport backend.

## Target shape

Conceptually:

```d
auto api = EditingApiClient(
    server: EditingApiServer("https://api.openstreetmap.org/api/0.6"),
    exchange: exchange);

OwnedNode node;
EditingApiStatus status;

if (!api.readNode(123, node, status))
{
    // status distinguishes local validation, transport, HTTP/OSM and codec
    // failures. A server-side conflict is not a network failure.
}
```

The exact constructor and exchange parameter types are deliberately deferred
until transport-d#3 is accepted. The OSM-domain names and operation semantics
are not delegated to transport-d.

Write/authenticated operations conceptually accept request-scoped authorization:

```d
Changeset changeset = ...;
long id;

if (!api.createChangeset(changeset, authorization, id, status))
{
    // authorization is not retained by the client.
}
```

The final API may use a provider/callback rather than a value if that better
matches credentials-d and transport-d. In either case secret bytes must not be
persisted or included in diagnostics.

## Operation families

The initial M17 surface is intentionally focused.

### Server/capability operations

- capabilities;
- editing permissions/scopes.

### Elements

For Node, Way and Relation where the OSM API supports them:

- current representation;
- a specific version;
- history;
- Way full;
- Relation full.

Multi-fetch/map endpoints are admitted only when a concrete consumer contract
is clear rather than merely because the server exposes them.

### Changesets

The semantic/XML foundation is provided by `osm.changeset`:

- `OwnedChangeset` represents server-returned Changeset state;
- `ChangesetTagRequest` represents the tag-only create/update request body;
- `readChangeset` / `readChangesetDocument` parse read/query XML;
- `writeChangesetTagRequest` serializes create/update XML without pretending
  that server-managed fields are writable.

The protocol client composes that foundation for:

- create;
- read;
- update;
- close;
- upload osmChange;
- parse/apply diffResult through the existing osm.upload/store APIs.

## Method naming

Public names should describe the object and action, not the wire path.

Preferred vocabulary:

```text
readNode
readNodeVersion
readNodeHistory

readWay
readWayVersion
readWayHistory
readWayFull

readRelation
readRelationVersion
readRelationHistory
readRelationFull

createChangeset
readChangeset
updateChangeset
closeChangeset
uploadChanges
```

If implementation evidence shows that overloads/read-family objects provide a
clearer D API, #141 may refine the exact spelling. It must preserve the same
domain-level clarity.

## Server value

The caller explicitly selects the API base URL. The value is non-secret and may
be retained by the client.

The library appends operation-relative API paths. Callers do not concatenate
`/node/`, `/history`, `/full`, `/changeset/` or upload paths themselves.

No write-capable operation silently defaults to the production OSM server.

## Request/response ownership

osm-d owns:

- operation-to-method mapping;
- path construction;
- required OSM media headers;
- XML/osmChange body encoding;
- bounded response codec selection;
- expected success statuses;
- OSM semantic status interpretation.

transport-d owns:

- generic request/response types;
- actual HTTP execution;
- timeout/redirect mechanics;
- generic response headers/status;
- body transfer and byte limits;
- transport failures and secret-safe provenance.

## Error direction

The protocol status must preserve enough information for a consumer to branch
without parsing strings.

Required dimensions are:

```text
local request/validation failure
transport failure
HTTP status
OSM semantic classification, when known
response codec/parse failure
```

Exact HTTP status remains available even when an OSM semantic classification is
also provided.

Representative semantic classes for qualification include authorization
required/denied, not found/gone, version conflict, precondition/reference
failure, payload/limit rejection and readonly/offline service state.

## Test seam

The transport/exchange object is injected.

A fake exchange must be able to verify:

- exact HTTP method;
- exact path/URL;
- ordinary headers;
- presence but not logging of sensitive authorization;
- bounded request body bytes;
- returned status/headers/body.

This is the normative CI seam. Live server tests are optional evidence and must
not mutate production OSM merely to satisfy CI.

## Sync/async

The client is synchronous at this layer.

A caller may run it through its executor/task system. osm-d does not own
threads, scheduling, retry loops or future/promise policy.

## Relationship to existing facades

`osm.api` composes existing focused pieces; it does not replace them.

- `osm.capabilities` remains useful for direct capability XML parsing.
- `osm.osmchange` remains the reusable change-document codec.
- `osm.upload` remains the reusable diffResult codec.
- `osm.store` remains the editable local-state and upload reconciliation
  layer.

Consumers that only need codecs do not need the protocol client.

## Documentation rule for #141

When the concrete transport contract is available, Ddoc for every public
operation must state:

- OSM operation and endpoint semantics;
- whether authorization is required/optional;
- request/response media type;
- ownership/allocation behavior;
- success and error/status behavior;
- whether the client retains any supplied value;
- a runnable unittest/example using a deterministic fake exchange where
  practical.
