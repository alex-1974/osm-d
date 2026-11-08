# v0.3 -> v0.4 API migration

**Status:** v0.4.0 release migration guide  
**Compatibility contract:** `API_STABILITY.md` defines the frozen v0.4.x
source contract.

v0.4 is primarily additive. It promotes the consumer surfaces developed after
v0.3.0 into the supported release contract. No supported v0.3.x symbol is
deliberately removed or renamed.

## New focused facades

### OSM topology and complete objects

```d
import osm.topology;
import osm.complete;
import osm.area;
```

`osm.topology` resolves Way/Relation references and provides bounded,
cycle-safe child/parent traversal. `osm.complete` projects resolved child
objects without materializing a second deep graph. `osm.area` assembles OSM
closed-Way and multipolygon topology into owning rings with exact Node IDs,
locations and source-Way provenance.

These modules deliberately stop before generic computational geometry:
intersection, clipping, containment, projection and spatial indexing remain
outside osm-d.

### Changesets and Editing API protocol

```d
import osm.changeset;
import osm.api;
```

`osm.changeset` models server-returned Changesets separately from the
tag-only request body used for create/update.

`osm.api` adds a synchronous OSM Editing API 0.6 client over an injected
`transport-d` `HttpExchange`. It owns OSM method/path/media/status semantics
for:

- capabilities and permissions;
- current/specific/history Node, Way and Relation reads;
- Way/Relation `full` reads;
- Changeset create/read/update/close;
- osmChange diff upload.

The caller still owns the selected server, credentials/OAuth flow, account
selection, retry/backoff and background execution. Authorization values are
request-scoped and are not retained by `EditingApiClient`.

### Authoritative history, refresh and conflict facts

```d
import osm.history;
import osm.sync;
```

Historical versions are separate from current live `OwnedNode`,
`OwnedWay` and `OwnedRelation` values. This matters particularly for a
deleted historical Node, which may legitimately have `visible=false` and no
location.

`osm.sync` exposes explicit base/local/remote states, structured conflict
facts and `reconcileAuthoritative`. It reports whether changes are local,
remote, identical, independent or overlapping; it does not silently invent an
automatic merge policy.

### Replication and incremental synchronization

```d
import osm.replication;
```

v0.4 exposes the complete replication boundary:

```text
caller-selected ByteSource
  -> compression-d streaming GZIP
  -> osmChange
  -> version/replay semantics
  -> transactional OsmStore reconciliation
  -> caller-persisted checkpoint
```

Use `readReplicationState` for bounded state metadata,
`replicationResourcePaths` for official-style relative resource paths and
`applyGzipReplicationStep` when the caller already has the compressed
`.osc.gz` resource as a `ByteSource`.

Sequence continuity is authoritative; timestamps are metadata. Object versions
are independently replay/stale/gap checked. Local dirty objects hand off to the
same M18 conflict semantics used by authoritative refresh. The returned
checkpoint advances only after successful final store application.

Retrieval scheduling, URL/base-path joining, retry/backoff and durable
checkpoint storage remain application responsibilities.

## Existing v0.3 workflows remain valid

The following v0.3 facades remain supported without source migration:

- `osm`;
- `osm.pbf`;
- `osm.store`;
- `osm.compare`;
- `osm.xml`;
- `osm.osmchange`;
- `osm.validate`;
- `osm.upload`;
- `osm.capabilities`.

The v0.3 request-aware `UploadResultEntry.effectFor` contract is unchanged.

## Suggested editor synchronization flow

A typical v0.4 consumer can now keep one semantic store across download,
editing, upload and background refresh:

```text
PBF/XML -> OsmStore
            |
            +-> local edits
            |     -> collectChanges
            |     -> validate
            |     -> osm.api upload
            |     -> applyUploadResult
            |
            +-> osm.api authoritative reads/history
            |     -> osm.sync conflict/reconcile
            |
            +-> replication state + .osc.gz
                  -> applyGzipReplicationStep
                  -> persist returned checkpoint
```

The application remains responsible for UI, worksets, credentials, scheduling
and persistence policy.

## Toolchain and compatibility

The release floor remains:

- D frontend 2.111;
- DUB 1.40.0.

The release qualification matrix remains:

- DMD 2.111.0, 2.112.1 and 2.113.0;
- LDC 1.41.0, 1.42.0 and 1.43.0;
- Ubuntu 24.04 x86_64.

v0.4.0 deliberately introduces no supported v0.3.x source break. Consumers may
upgrade the dependency to:

```sdl
dependency "osm-d" version="~>0.4.0"
```

and adopt the new focused facades incrementally.
