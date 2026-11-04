# v0.3 API direction

**Status:** development contract for the next minor release line  
**Published compatibility contract:** `API_STABILITY.md` remains the v0.2.x
source contract until a later release explicitly freezes a new line.

v0.3 development starts from the fully qualified v0.2.1 state. M11 is additive:
it does not remove, rename or weaken any supported v0.2.x symbol.

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

## Bounded parsing

`UploadResultReader` uses the existing transport-d/dxml XML boundary.
`UploadResultReadOptions.maximumEntries` provides an explicit response bound;
zero selects the documented default of 100,000 entries.

Streaming callbacks preserve source order. The one-shot materializing helpers
are transactional and leave the destination at `.init` on failure.

Unknown root/entry attributes and unsupported content fail explicitly.

## Compatibility direction

M11 adds a new facade rather than expanding `import osm;`. This follows the
v0.2 API cleanup: specialized wire-format families remain opt-in and the common
root stays focused on ordinary semantic/store/PBF traversal work.

Further v0.3 work must not silently broaden this facade into an HTTP/account
client. A future network abstraction requires a separate responsibility/API
decision.
