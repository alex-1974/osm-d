# ADR 0034 — OSM replication sequence, replay and checkpoint contract

Status: accepted for M19
Date: 2026-11-08
Issues: #149, #150, #151, #152, #153

## Context

M17 and M18 provide protocol-independent OSM element reading, history,
authoritative refresh and conflict classification. A long-running consumer still
needs a reusable contract for applying official-style OpenStreetMap replication
feeds without duplicating sequence, replay and checkpoint rules.

The public OSM replication feeds publish compressed osmChange resources plus
state metadata. Minute, hour and day feeds use monotonically increasing sequence
numbers. A sequence number identifies one feed state; it is not derived from
wall-clock arithmetic. State timestamps are synchronization metadata, but data
inside a diff may have timestamps equal to or earlier than the preceding state
timestamp. Consumers therefore must tolerate already-known object versions.

The current public feed layout identifies a sequence N as three groups of three
decimal digits:

```text
AAA/BBB/CCC.osc.gz
AAA/BBB/CCC.state.txt

N = AAA * 1_000_000 + BBB * 1_000 + CCC
```

The current state metadata required for safe continuation is
`sequenceNumber` plus `timestamp`. Historical Osmosis transaction fields are
generator internals and are not part of osm-d's stable replication model.

## Decision

### 1. Replication vocabulary

M19 uses these semantic terms consistently:

- **feed** — one caller-selected replication stream;
- **feed identity** — an opaque stable identifier supplied by the caller so a
  checkpoint cannot silently move between different streams or mirrors;
- **granularity** — minute, hour, day or custom/other;
- **sequence** — the monotonically increasing replication sequence number;
- **state** — parsed metadata describing one sequence, currently sequence plus
  feed timestamp;
- **checkpoint** — the state that the caller says is already reflected by the
  target store;
- **step** — one candidate transition from checkpoint sequence N to state N+1;
- **replay** — input whose OSM object versions are already represented by the
  target store;
- **gap** — a missing replication sequence or missing OSM object version that
  prevents safe continuation.

The eventual D API should expose strong replication-domain values instead of
passing unrelated integers and strings through the apply path. Exact public
type names are finalized by #150, but these semantic distinctions are fixed by
this ADR.

### 2. Feed identity is transport-independent

osm-d does not own a base URL, HTTP client or filesystem path.

A replication checkpoint nevertheless belongs to one specific feed. The caller
therefore supplies an opaque feed identifier together with its granularity.
Examples include an application-defined identifier for the official minute
feed or for a trusted mirror.

osm-d compares feed identity before accepting a step. It does not interpret the
identifier as a URL and does not perform network access.

This prevents a valid sequence number from one feed from accidentally advancing
a checkpoint belonging to another.

### 3. State files expose only semantic continuation fields

The stable replication state projection contains:

- sequence number;
- feed timestamp.

The state parser introduced by #150 must:

- require exactly one valid `sequenceNumber`;
- require exactly one valid `timestamp`;
- accept the escaped-colon timestamp form used by replication state files;
- validate the supported timestamp syntax and normalize it to one UTC value;
- ignore unrelated generator-internal key/value fields;
- reject duplicate required fields or malformed required values;
- apply explicit input-size/line limits.

Fields such as `txnMax`, `txnMaxQueried`, `txnReadyList` and
`txnActiveList` are not promoted into stable osm-d API merely because older
generators emitted them.

### 4. Sequence continuity is authoritative

For a checkpoint at sequence C and candidate state S:

| Relationship | Meaning | M19 action |
| --- | --- | --- |
| S == C + 1 | expected next step | eligible for apply |
| S == C | sequence replay/restart | already applied; checkpoint unchanged |
| S < C | stale sequence | ignore/reject as stale; never roll back |
| S > C + 1 | sequence gap | continuity error |
| feed differs | wrong stream | feed mismatch |

Sequence arithmetic, not timestamps, decides continuity.

A state timestamp is retained because consumers need it for diagnostics,
initial synchronization and checkpoint evidence. M19 does not infer a sequence
number from elapsed time and does not reject a valid next sequence merely
because object timestamps overlap the previous state boundary.

For same-sequence replay, materially different state metadata is treated as an
inconsistent feed state rather than silently accepted as the same checkpoint.

### 5. There is no implicit initial checkpoint

osm-d does not guess which replication sequence corresponds to an arbitrary
store snapshot.

Before incremental application begins, the caller must establish a checkpoint
that matches the target store. Typical sources include:

- replication metadata embedded in an imported PBF;
- a state file deliberately chosen for the imported snapshot;
- an application-specific trusted baseline.

This keeps the dangerous "start from whatever is current now" policy outside
the library.

### 6. Object replay is version-based, not timestamp-based

Within an eligible next sequence, OSM element identity and version are the
authoritative replay key.

For a tracked current object at authoritative version V:

- incoming V with equivalent semantic payload is harmless replay;
- incoming V with a different semantic payload is an integrity conflict;
- incoming V + 1 is the ordinary next authoritative version;
- incoming version < V is stale and does not overwrite the newer state;
- incoming version > V + 1 is an object-version gap unless the missing
  transitions are present earlier in the same staged replication document.

The same rule applies when several versions of one object occur in one
aggregated/full-history diff: M19 validates the per-object version chain before
mutating the store.

Object timestamps may support diagnostics but never substitute for version
continuity.

### 7. Missing objects distinguish create from unknown baseline

A genuinely new OSM object can enter an authoritative current-state store
through a replication `create` beginning at version 1.

A `modify` or `delete` for an identity whose prior authoritative state is
unknown cannot by itself prove continuity. M19 must not fabricate the missing
baseline merely because the incoming version is greater than 1.

Known authoritative tombstones may provide the prior version required for
undelete/subsequent-version validation.

Direct replication application therefore assumes that the caller supplies a
change stream intentionally in scope for the target dataset. M19 does not add
spatial filtering or infer membership of an arbitrary partial extract.

### 8. One sequence is staged before store mutation

#150 implements one replication sequence as a semantic transaction:

1. validate feed/checkpoint/sequence continuity;
2. parse/materialize or stream-stage the complete osmChange input under bounds;
3. validate every per-object version transition, including repeated identities;
4. reduce each identity to its final authoritative state while retaining apply
   statistics;
5. hand the final authoritative states to the existing M18 reconciliation
   machinery;
6. produce the next checkpoint only after successful semantic application.

This reuses M18's local-edit/conflict model instead of inventing a second
replication conflict policy.

Data/contract failures are detected before visible mutation. As in M18,
catastrophic process/resource failure is not handled by cloning an entire
city-scale store solely to promise rollback after out-of-memory.

### 9. Local edits remain M18 conflicts

Replication is authoritative remote input.

When a target identity is locally dirty, M19 uses the M18 base/local/remote
classification and reconciliation rules:

- local-only work stays local;
- identical concurrent state may be acknowledged;
- independent/overlapping concurrent state is reported/deferred according to
  the M18 contract;
- replication does not silently choose remote-wins.

A replication sequence may therefore be semantically valid while containing
one or more locally conflicting objects. #150 chooses the conservative
transaction boundary: every final remote state is classified against M18 before
the first store mutation. If any identity requires resolution, the step returns
`localConflict`, exposes the conflict reports, leaves the store unchanged and
does not advance the checkpoint. The caller may resolve local work and replay
the same sequence.

Only a conflict-free staged batch reaches `reconcileAuthoritative`. This keeps
checkpoint progression and the store's retained authoritative version aligned
without introducing a second pending-remote-state database inside osm-d.

### 10. Intermediate reference incompleteness is permitted

OSM replication may update referenced Nodes, Ways and Relations in an order
that temporarily leaves unresolved positive references.

M19 does not require full referential completeness after every individual
entry. It preserves the existing osm-d partial-dataset/reference rules and
checks index coherence through ordinary store mutation paths.

This avoids rejecting otherwise valid replication batches solely because
related objects are ordered differently.

### 11. Resource paths are OSM semantics; retrieval is not

For the current official-style layout, #150 may expose deterministic helpers
for the relative resources associated with a supported sequence:

```text
AAA/BBB/CCC.osc.gz
AAA/BBB/CCC.state.txt
```

The helper owns only formatting/validation of the OSM replication path. Joining
that relative path to a base URL, opening a file, HTTP execution, retries and
redirect policy remain in transport-d/application code.

The nine-decimal-digit official layout is the admitted baseline. Values outside
that representable layout fail explicitly unless later upstream evidence
requires extending the contract.

### 12. Compression remains outside osm-d

M19 does not embed another GZIP/DEFLATE implementation.

The bounded compressed-input pipeline in #151 composes:

```text
transport-d ByteSource
        |
        v
compression-d streaming GZIP
        |
        v
osm-d osmChange reader
        |
        v
M19 staged application
```

Until compression-d exposes a stable consumer-qualified streaming GZIP
contract, #151 remains dependency-blocked. #149 and #150 do not depend on that
provider work.

### 13. Checkpoint persistence remains application-owned

osm-d returns a candidate next checkpoint only after a successful sequence
application.

It does not:

- write checkpoint files/databases;
- schedule polling;
- decide retry/backoff;
- monitor feed health;
- make store persistence and checkpoint persistence one external database
  transaction.

Applications that require crash-atomic persistence across both their durable
store and checkpoint must provide that persistence transaction above osm-d.

M19 still guarantees idempotent restart semantics so a sequence can be safely
replayed when store mutation completed but the caller did not persist the new
checkpoint.

## Consequences

### Positive

- sequence continuity is deterministic and independent of clocks;
- restart after a missed checkpoint write can be idempotent;
- object gaps cannot be silently hidden by a later version;
- local edits reuse one existing conflict vocabulary;
- generator-specific state-file fields do not pollute the public API;
- resource retrieval and compression stay replaceable workspace dependencies;
- the same core apply semantics works with local fixtures, files or remote
  transports.

### Trade-offs

- callers must establish an explicit initial checkpoint;
- arbitrary partial extracts cannot be kept globally synchronized merely by
  handing every official replication diff to the store;
- same-version/different-payload input is treated as integrity failure rather
  than "last write wins";
- complex durable crash-atomic persistence remains above the in-memory library.

## Qualification required by M19

#150–#152 must cover at least:

- state parsing with ordinary and extra generator fields;
- canonical sequence path formatting;
- next/replayed/stale/gapped sequence relationships;
- same-sequence state mismatch;
- duplicate same-version object replay;
- same-version payload mismatch;
- multiple contiguous versions of one object in one sequence;
- object-version gaps;
- create/modify/delete and undelete/tombstone progression;
- local dirty-object handoff to M18;
- parent-index coherence;
- no checkpoint advancement after malformed/corrupt/incomplete input;
- restart after store-applied/checkpoint-not-persisted state;
- DMD/LDC and external consumer compilation.

## Upstream evidence

- OpenStreetMap Wiki, Planet.osm/diffs:
  https://wiki.openstreetmap.org/wiki/Planet.osm/diffs
- OpenStreetMap Wiki, PBF Format replication fields:
  https://wiki.openstreetmap.org/wiki/PBF_Format
- OpenStreetMap Wiki, Osmosis/Replication:
  https://wiki.openstreetmap.org/wiki/Osmosis/Replication

The contract intentionally models the current documented semantics rather than
historical generator implementation details.
