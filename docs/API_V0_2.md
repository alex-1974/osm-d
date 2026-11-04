# v0.2 API direction

**Status:** development contract for the next pre-1.0 release line  
**Baseline:** v0.1.0 remains published and source-compatible under `API_STABILITY.md`

v0.2 deliberately improves consumer ergonomics after the first independent
release cycle. These changes may break v0.1 source where the old surface
exposed duplicate representation names or specialized PBF facilities from the
package root. Data-integrity, ownership, lifetime and fail-closed contracts are
not weakened.

## Preferred entry points

Use:

- `import osm;` for common OSM semantic values, borrowed PBF traversal and the
  editable store;
- `import osm.pbf;` for loss-aware PBF documents, preservation, PBF writing,
  parallel summary decoding and PBF-specific semantic comparison;
- `import osm.store;` for the editable store facade;
- `import osm.compare;` for serialization-independent OSM/change comparisons;
- `import osm.xml;` for ordinary OSM XML;
- `import osm.osmchange;` for osmChange;
- `import osm.validate;` for upload-readiness validation.

Low-level codec, wire and compact-store implementation modules remain outside
the preferred compatibility surface.

## Shared semantic values

PBF and the compact store use the same leaf vocabulary:

- `TagView`;
- `MetadataView`;
- `NodeRefView`;
- `RelationMemberView`;
- `LocationView`.

Store ranges remain store-specific because they borrow from store-managed
storage and have store mutation invalidation rules. Their `front` values do
not need a second `Store*View` vocabulary.

## Node references

A Way contains references to Nodes, not embedded Node objects.

| v0.1 name | v0.2 preferred name |
| --- | --- |
| `WayNodeView` | `NodeRefView` |
| `WayNodeRange` | `NodeRefRange` |
| `OwnedWayNode` | `OwnedNodeRef` |
| `StoreWayNodeView` | `NodeRefView` |
| `StoreWayNodeRange` | `StoreNodeRefRange` |

Old direct-module names remain aliases where practical for migration, but are
not re-exported from the preferred root/facade surface.

## Store lookup

Stable `OsmHandle` values remain important for editor identity across
replacement, delete/restore and authoritative server-ID remapping. They are not
required merely to read a known OSM ID.

```d
StoreNodeView node;
StoreStatus status;

if (store.node(123, node, status))
{
    // node.handle remains available when stable identity is needed.
}
```

Equivalent typed methods exist for Ways and Relations. The generic
`find(ElementType, OsmId, OsmHandle)` plus handle-based access remains
available for generic/editor workflows.

A missing typed lookup returns `false`, resets the output view, and reports
`StoreError.notFound` with the requested type and ID.

## PBF reading

One-shot complete reads no longer require caller-managed scratch:

```d
Handler handler;
auto result = readPbf(bytes, handler);

if (!result.ok)
{
    // result.status
}
```

`PbfReadResult` contains summary and status.

Repeated/high-throughput callers retain the existing explicit API:

```d
PbfReader reader;
PbfReaderWorkspace workspace;

reader.read(bytes, workspace, handler, summary, status);
```

This preserves scratch-capacity reuse and the established hot-path contract.

Element-specific traversal also has discoverable free entry points:

```d
foreach (scope ref NodeView node; pbfNodes(bytes))
{
    // ...
}
```

`pbfWays` and `pbfRelations` follow the same pattern. The existing
`PbfReader.nodes/ways/relations` methods remain available.

## Focused PBF facade

The following specialized families move out of the preferred `import osm;`
root and into `import osm.pbf;`:

- `PbfDocument`, `PbfHeader` and raw-preservation state;
- `readPbfDocument`;
- `PbfWriter` and write options/status;
- `PbfParallelReader`;
- PBF-specific semantic comparison helpers.

Generic semantic comparison helpers such as `sameOsmSemantics` and
`sameChangeSemantics` use the focused `osm.compare` facade. The underlying
`osm.model.compare` module remains available for v0.1 direct-import compatibility.

## Exact text bytes

Tag keys/values, usernames and relation roles continue to expose exact bytes.
The workspace currently has no shared, qualified UTF-8/TextView abstraction.
v0.2 therefore does not invent an osm-specific string wrapper or silently
validate, repair or transcode source bytes.

## Workspace-library reuse audit

### transport-d

Keep `transport-d` as the byte-resource boundary for XML/osmChange and future
resource-oriented I/O. osm-d does not add a competing file/HTTP/stream
hierarchy.

### containers-d

`containers-d` v0.3.1 provides reusable ring buffers, scratch storage and a
bounded synchronized `BlockingQueue`. Its current queue intentionally uses
**non-blocking producer admission** (`tryPush -> full`) and blocking consumer
removal.

The PBF parallel-summary pipeline requires producer backpressure that blocks
while the bounded queue is full. Replacing that contract with a spin/yield loop
merely to reuse a type would change scheduling/performance semantics. The
private queue is retained until a shared primitive matches the required
contract or measurements justify a different policy.

### concurrency-d

Its executor/structured-task model is broader than this PBF reader needs and
would import scheduling/lifetime policy that is not part of the reader API. It
is not adopted for this slice.

### compression-d

The repository currently describes itself as compression research without a
stable release/public API promise. osm-d therefore retains its existing bounded
zlib backend. Re-evaluate compression-d when it has a qualified consumer
release and matching bounded-decompression contract.

### raster-d and other domain libraries

No reusable OSM-domain API primitive was identified for this slice. New generic
implementation needs should repeat the workspace reuse check.

## Migration summary

```d
// v0.1
WayNodeView refValue;
OwnedWayNode ownedRef;

// v0.2
NodeRefView refValue;
OwnedNodeRef ownedRef;
```

```d
// v0.1
OsmHandle handle;
if (store.find(ElementType.node, 123, handle))
    store.node(handle, node, status);

// v0.2 ordinary lookup
store.node(123, node, status);
```

```d
// v0.1 one-shot
PbfReader reader;
PbfReaderWorkspace workspace;
reader.read(bytes, workspace, handler, summary, status);

// v0.2 one-shot
auto result = readPbf(bytes, handler);
```

Code using loss-aware PBF documents/writing should add:

```d
import osm.pbf;
```

No migration should require weaker lifetime handling, validation or
data-integrity checks.
