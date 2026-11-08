# ADR 0032: osm-d owns OSM Editing API protocol semantics, not network execution

- Status: Accepted
- Date: 2026-11-06
- Related: #139, #140, #141, #142, #143
- References:
  - ADR 0019 transport byte-resource I/O
  - ADR 0025 store change/upload bridge
  - ADR 0026 diffResult codec
  - ADR 0027 API capabilities projection
  - transport-d#3 generic bounded HTTP request/response exchange

## Context

v0.3 deliberately stopped osm-d at Editing API codecs and validation. The
tracked architecture therefore states that HTTP methods, endpoint URLs,
authentication and changeset creation/closing are application concerns.

That boundary is too narrow for a reusable OSM library.

A consumer should not have to know that a changeset is created with one HTTP
method and path, that a Way full request uses another path, which media type an
osmChange upload requires, or which non-2xx statuses have OSM-specific
conflict/precondition meaning. Those are OSM protocol facts rather than generic
networking or editor workflow policy.

At the same time, osm-d must not grow a second HTTP stack, credential vault,
OAuth implementation, scheduler or editor service layer.

## Decision

### osm-d owns OSM protocol knowledge

The post-v0.3 Editing API layer owns:

- API 0.6 operation names and endpoint-path construction;
- the HTTP method required by each supported OSM operation;
- OSM request and response media semantics;
- XML/body codec selection;
- success-status expectations;
- OSM-specific interpretation of HTTP/server failures;
- changeset protocol operations: create, read, update, close and upload;
- the OSM permission/scope meaning required by operations.

Existing semantic codecs such as osmChange, diffResult and capability parsing
are reused rather than duplicated.

### transport-d owns generic HTTP execution

Network execution remains outside osm-d. The required provider boundary is the
generic bounded HTTP exchange requested in transport-d#3.

transport-d owns generic concerns such as:

- HTTP/TLS/curl/socket execution;
- generic method, URL, header and body exchange;
- timeouts and redirect mechanics;
- request/response byte limits;
- transport failures;
- response status and ordinary headers;
- provenance that never exposes secret values.

osm-d must not import std.net.curl or another HTTP backend to bypass this
boundary.

### The consumer selects the server

osm-d does not silently choose the production OpenStreetMap server.

The protocol client accepts an explicit base API URL/server value. It appends
OSM operation-relative paths to that configured base.

This permits:

- openstreetmap.org;
- development/test OSM servers;
- mirrors or compatible deployments;
- deterministic fake transports.

A future convenience constant for a well-known public server may be additive,
but write-capable code must never depend on an implicit production target.

### Authorization is request-scoped, not owned by osm-d

osm-d may describe that an operation requires or may use authorization and may
accept a request-scoped authorization provider/value required to perform the
generic exchange.

osm-d must not:

- persist access or refresh tokens;
- copy secret header values into diagnostics, provenance or errors;
- perform OAuth2 authorization-code/PKCE login;
- select accounts;
- refresh credentials;
- define credential-at-rest policy.

Credential storage/protection belongs in credentials-d. OAuth workflow and
account selection remain application or future generic OAuth-layer concerns.

The transport boundary must support sensitive headers without exposing their
values through ordinary diagnostics.

### Changeset protocol versus changeset policy

osm-d owns the protocol operations required to create, read, update, close and
upload a changeset.

The application owns policy such as:

- when to open a changeset;
- whether to reuse or rotate it;
- when to close it;
- retry/backoff;
- editor worksets and undo/history UI.

This is the same distinction as owning a file format without deciding when an
application saves a document.

### Error layers remain distinct

The public protocol layer must preserve these classes:

```text
local validation / request construction failure
        |
transport failure
        |
HTTP response status
        |
OSM protocol/server semantic classification
        |
response-body parse/codec failure
```

A valid HTTP response such as an OSM conflict or precondition failure is not a
transport failure.

Where current OSM behavior justifies a semantic classification, the protocol
layer may expose it. Unknown/unmapped HTTP responses retain their exact status
and bounded diagnostic body/metadata subject to redaction and limits.

### Synchronous baseline, caller-controlled async

The protocol client is synchronous at the transport seam.

Async composition remains caller/executor controlled. osm-d does not create a
scheduler, thread pool, retry loop or background worker merely to offer an
asynchronous-looking API.

### Injected exchange is the test seam

The protocol layer depends on a generic exchange contract rather than a concrete
HTTP backend.

Every operation must therefore be testable with a deterministic fake/mock
exchange that records the request and returns a bounded response without
network access.

Protocol tests assert method, path, headers, body, status mapping and codec
behavior independently from live networking.

### Public direction

The intended focused facade is:

```d
import osm.api;
```

with an `EditingApiClient` consumer surface. transport-d 0.2.0 now provides
the required `HttpExchange` contract, so the concrete constructor injects that
generic exchange together with explicit server configuration and optional
generic limits/options.

The public API should read in OSM domain terms: consumers ask for a Node,
history, full Way, Changeset creation or an osmChange upload. They do not
hand-write endpoint paths or HTTP methods.

The client may retain non-secret server configuration and generic transport
state. Authorization material is supplied only at request execution boundaries.

## Dependency boundary

```text
                         +-----------------------+
credentials-d ----------> scoped secret/header  |
                         +-----------+-----------+
                                     |
                                     v
+------------------+     +-----------+-----------+     +------------------+
| application      |---->| osm-d protocol layer  |---->| transport-d      |
| policy           |     |                       |     | HTTP exchange    |
|                  |     | method/path/media     |     | TLS/socket/curl  |
| retry/backoff    |     | OSM status meaning    |     | limits/status    |
| account choice   |     | changeset operations  |     | generic errors   |
| changeset timing |     | XML/body codecs       |     | redaction        |
+------------------+     +-----------+-----------+     +--------+---------+
                                     |                          |
                                     v                          v
                              OSM semantic values             network
```

OAuth2/PKCE login and token refresh sit beside the application/credential
boundary, not inside osm-d.

## Consequences

Consumers gain one reusable OSM protocol layer instead of duplicating endpoint,
method, media-type and status knowledge.

Existing v0.3 codec work remains valid and becomes the protocol layer's codec
foundation.

transport-d remains the only generic HTTP/network implementation dependency.

Secret ownership remains outside osm-d.

The protocol layer can be fully qualified without destructive live-server CI.

transport-d 0.2.0 satisfies the generic HTTP provider dependency requested in
transport-d#3. M17 therefore implements the protocol client directly over
`HttpExchange`; osm-d contains no private curl/std.net.curl path.

## Historical v0.3 contract

docs/API_V0_3.md remains a truthful description of the released v0.3.x surface:
that release did not contain an HTTP/protocol client.

This ADR changes the architecture for post-v0.3 development. It does not rewrite
the historical release contract.

## Alternatives rejected

### Keep all HTTP method/path knowledge in applications

Rejected because OSM endpoint/method/media/status rules are protocol semantics
that every consumer would otherwise duplicate.

### Implement HTTP directly in osm-d

Rejected because transport execution is generic infrastructure already owned by
transport-d and would create competing I/O abstractions.

### Store bearer tokens in EditingApiClient

Rejected because secret lifetime/storage and account selection are separate
security domains and would make a protocol library a credential manager.

### Put changeset open/close entirely in the application

Rejected as a protocol boundary. The application decides when to perform those
operations, but osm-d should know how the OSM protocol performs them.

### Add internal async/retry scheduling

Rejected because scheduling and retry policy are application concerns and would
unnecessarily complicate the synchronous, deterministic protocol seam.
