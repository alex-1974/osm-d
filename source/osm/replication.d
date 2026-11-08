/**
 * OpenStreetMap replication state, path and incremental apply semantics.
 *
 * Networking, compression, scheduling and checkpoint persistence are outside
 * this module. The caller supplies parsed/decoded resources and owns durable
 * checkpoint storage.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-08
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.replication;

import compression.core :
    DecodeError,
    DecodeLimits;
import osm.io.gzip_source :
    GzipDecodedSource,
    GzipSourceFailure;
import osm.io.osmchange.document :
    OsmChangeDocument;
import osm.io.osmchange.reader :
    OsmChangeReadError,
    OsmChangeReadOptions,
    OsmChangeReadStatus,
    readOsmChangeDocument;
import osm.model.change :
    ChangeAction,
    ChangeObjectState,
    OwnedChangeEntry;
import osm.model.conflict :
    ConflictReport,
    ConflictDisposition,
    NodeState,
    RelationState,
    WayState,
    classifyConflict;
import osm.model.owned :
    OwnedNode,
    OwnedRelation,
    OwnedWay;
import osm.reconcile.authoritative :
    AuthoritativeBatch,
    ReconcileResult,
    ReconcileStatus,
    reconcileAuthoritative;
import osm.store :
    OsmHandle,
    OsmStore;
import osm.view.element :
    ElementType,
    OsmId;
import std.algorithm.sorting : sort;
import std.format : format;
import transport.source :
    ByteSource,
    ReadError;

/** Caller-selected replication cadence. */
enum ReplicationGranularity : ubyte
{
    minute,
    hour,
    day,
    custom,
}

/**
 * Identity of one replication stream.
 *
 * id is opaque to osm-d. It may identify the official feed, a mirror, or
 * another trusted source. It is not interpreted as a URL.
 */
struct ReplicationFeed
{
    string id;
    ReplicationGranularity granularity;

    @property bool valid() const @safe pure nothrow @nogc
    {
        return id.length != 0;
    }

    static bool create(
        string id,
        ReplicationGranularity granularity,
        out ReplicationFeed result) @safe
    {
        result = ReplicationFeed.init;
        if (id.length == 0)
            return false;

        result.id = id.idup;
        result.granularity = granularity;
        return true;
    }
}

/** Normalized UTC timestamp retained from replication state metadata. */
struct ReplicationTimestamp
{
    /// Whether a semantic UTC value is present.
    bool hasValue;

    /**
     * Canonical unescaped UTC form when it originated from state.txt.
     *
     * Empty is valid for timestamps created directly from Unix seconds.
     */
    string isoUtc;

    /// Seconds since 1970-01-01T00:00:00Z.
    long unixSeconds;

    @property bool valid() const @safe pure nothrow @nogc
    {
        return hasValue;
    }

    /** Construct a timestamp from PBF/application Unix-epoch metadata. */
    static ReplicationTimestamp fromUnixSeconds(long seconds)
        @safe pure nothrow @nogc
    {
        ReplicationTimestamp result;
        result.hasValue = true;
        result.unixSeconds = seconds;
        return result;
    }
}

/** Parsed semantic subset of one replication state file. */
struct ReplicationState
{
    ulong sequenceNumber;
    ReplicationTimestamp timestamp;

    @property bool valid() const @safe pure nothrow @nogc
    {
        return sequenceNumber <= maximumReplicationSequence &&
               timestamp.valid;
    }
}

/** Durable semantic synchronization point owned/persisted by the caller. */
struct ReplicationCheckpoint
{
    ReplicationFeed feed;
    ReplicationState state;

    @property bool valid() const @safe pure nothrow @nogc
    {
        return feed.valid && state.valid;
    }
}

/** Bounded controls for reading one state.txt resource. */
struct ReplicationStateReadOptions
{
    /// Maximum complete state resource bytes. Zero selects 1 MiB.
    size_t maximumBytes;

    /// Maximum physical line bytes. Zero selects 256 KiB.
    size_t maximumLineBytes;

    /// Chunk size used with ByteSource.readSome. Zero selects 4096 bytes.
    size_t chunkSize;
}

/** Stable failure class for replication state parsing. */
enum ReplicationStateReadError : ubyte
{
    none,
    nullSource,
    transportFailure,
    resourceLimit,
    malformedLine,
    duplicateSequence,
    duplicateTimestamp,
    missingSequence,
    missingTimestamp,
    invalidSequence,
    invalidTimestamp,
}

/** Diagnostic for one state.txt read. */
struct ReplicationStateReadStatus
{
    ReplicationStateReadError error = ReplicationStateReadError.none;
    ReadError transportError = ReadError.none;
    size_t lineNumber;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == ReplicationStateReadError.none;
    }
}

/** Current official-style relative resource paths for one sequence. */
struct ReplicationResourcePaths
{
    string change;
    string state;
}

enum ReplicationPathError : ubyte
{
    none,
    sequenceOutOfRange,
}

struct ReplicationPathStatus
{
    ReplicationPathError error = ReplicationPathError.none;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == ReplicationPathError.none;
    }
}

/** Relationship of a candidate state to the caller's checkpoint. */
enum ReplicationStepRelation : ubyte
{
    next,
    replay,
    stale,
    gap,
    feedMismatch,
    stateMismatch,
    invalid,
}

/** Stable replication-step application failure. */
enum ReplicationApplyError : ubyte
{
    none,
    nullStore,
    invalidFeed,
    invalidCheckpoint,
    feedMismatch,
    stateMismatch,
    staleSequence,
    sequenceGap,
    invalidChangeEntry,
    unknownBaseline,
    invalidTransition,
    versionGap,
    payloadMismatch,
    localConflict,
    reconcileFailure,
}

/** Diagnostic for a rejected step. */
struct ReplicationApplyStatus
{
    ReplicationApplyError error = ReplicationApplyError.none;
    ElementType type;
    OsmId id;
    int incomingVersion;
    int knownVersion;
    size_t entryIndex;
    ReconcileStatus reconcileStatus;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == ReplicationApplyError.none;
    }
}

/** Observable result of one accepted/replayed replication step. */
struct ReplicationApplyResult
{
    /// Checkpoint the caller may persist after success.
    ReplicationCheckpoint checkpoint;

    bool checkpointAdvanced;
    bool sequenceReplay;

    size_t inputEntries;
    size_t stagedIdentities;
    size_t stagedTransitions;
    size_t replayedEntries;
    size_t staleEntries;

    /**
     * M18 reconciliation facts for the final authoritative states.
     *
     * Empty for a same-sequence replay or for a step containing only stale /
     * already-known object versions.
     */
    ReconcileResult reconciliation;

    /**
     * Local-edit conflicts found during preflight.
     *
     * On localConflict no store mutation occurs and checkpoint remains the
     * caller-supplied checkpoint.
     */
    ConflictReport[] conflicts;
}

/// Highest sequence representable by the current nine-digit official layout.
enum ulong maximumReplicationSequence = 999_999_999;

/**
 * Parse one bounded OpenStreetMap replication state.txt resource.
 *
 * Required semantic fields are sequenceNumber and timestamp. Blank lines and
 * Java-properties-style '#'/'!' comment lines are ignored. Other key/value
 * fields are deliberately ignored as generator implementation details.
 */
bool readReplicationState(
    ByteSource source,
    out ReplicationState state,
    out ReplicationStateReadStatus status,
    ReplicationStateReadOptions options = ReplicationStateReadOptions.init)
    @safe
{
    state = ReplicationState.init;
    status = ReplicationStateReadStatus.init;

    if (source is null)
    {
        status.error = ReplicationStateReadError.nullSource;
        return false;
    }

    ubyte[] bytes;
    if (!readStateBytes(source, bytes, status, options))
        return false;

    string text;
    if (!asciiText(bytes, text))
    {
        status.error = ReplicationStateReadError.malformedLine;
        return false;
    }

    bool hasSequence;
    bool hasTimestamp;
    ulong sequence;
    ReplicationTimestamp timestamp;

    const maximumLine = options.maximumLineBytes == 0
        ? 256 * 1024
        : options.maximumLineBytes;

    size_t lineStart;
    size_t lineNumber = 1;
    while (lineStart <= text.length)
    {
        size_t lineEnd = lineStart;
        while (lineEnd < text.length && text[lineEnd] != '\n')
            ++lineEnd;

        const(char)[] line = text[lineStart .. lineEnd];
        if (line.length != 0 && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];

        status.lineNumber = lineNumber;

        if (line.length > maximumLine)
        {
            status.error = ReplicationStateReadError.resourceLimit;
            return false;
        }

        line = trimAscii(line);
        if (line.length != 0 &&
            line[0] != '#' &&
            line[0] != '!')
        {
            size_t equals = size_t.max;
            foreach (i, ch; line)
            {
                if (ch == '=')
                {
                    equals = i;
                    break;
                }
            }

            if (equals == size_t.max)
            {
                status.error = ReplicationStateReadError.malformedLine;
                return false;
            }

            const key = trimAscii(line[0 .. equals]);
            const value = trimAscii(line[equals + 1 .. $]);

            if (key == "sequenceNumber")
            {
                if (hasSequence)
                {
                    status.error =
                        ReplicationStateReadError.duplicateSequence;
                    return false;
                }
                if (!parseSequence(value, sequence))
                {
                    status.error =
                        ReplicationStateReadError.invalidSequence;
                    return false;
                }
                hasSequence = true;
            }
            else if (key == "timestamp")
            {
                if (hasTimestamp)
                {
                    status.error =
                        ReplicationStateReadError.duplicateTimestamp;
                    return false;
                }
                if (!parseReplicationTimestamp(value, timestamp))
                {
                    status.error =
                        ReplicationStateReadError.invalidTimestamp;
                    return false;
                }
                hasTimestamp = true;
            }
            // Unknown generator-specific properties are intentionally ignored.
        }

        if (lineEnd == text.length)
            break;
        lineStart = lineEnd + 1;
        ++lineNumber;
    }

    if (!hasSequence)
    {
        status.error = ReplicationStateReadError.missingSequence;
        return false;
    }
    if (!hasTimestamp)
    {
        status.error = ReplicationStateReadError.missingTimestamp;
        return false;
    }

    state.sequenceNumber = sequence;
    state.timestamp = timestamp;
    status = ReplicationStateReadStatus.init;
    return true;
}

/**
 * Format the canonical official-style relative diff/state paths.
 *
 * Retrieval and joining with a base URL/path remain caller/transport concerns.
 */
bool replicationResourcePaths(
    ulong sequenceNumber,
    out ReplicationResourcePaths paths,
    out ReplicationPathStatus status) @safe
{
    paths = ReplicationResourcePaths.init;
    status = ReplicationPathStatus.init;

    if (sequenceNumber > maximumReplicationSequence)
    {
        status.error = ReplicationPathError.sequenceOutOfRange;
        return false;
    }

    const a = cast(uint)(sequenceNumber / 1_000_000);
    const b = cast(uint)((sequenceNumber / 1_000) % 1_000);
    const c = cast(uint)(sequenceNumber % 1_000);
    const stem = format("%03d/%03d/%03d", a, b, c);

    paths.change = stem ~ ".osc.gz";
    paths.state = stem ~ ".state.txt";
    return true;
}

/** Classify one candidate state relative to a caller-owned checkpoint. */
ReplicationStepRelation classifyReplicationStep(
    scope ref const ReplicationCheckpoint checkpoint,
    scope ref const ReplicationFeed feed,
    scope ref const ReplicationState candidate)
    @safe pure nothrow @nogc
{
    if (!checkpoint.valid || !feed.valid || !candidate.valid)
        return ReplicationStepRelation.invalid;

    if (!sameFeed(checkpoint.feed, feed))
        return ReplicationStepRelation.feedMismatch;

    const current = checkpoint.state.sequenceNumber;
    const incoming = candidate.sequenceNumber;

    if (incoming == current)
    {
        return sameTimestamp(checkpoint.state.timestamp, candidate.timestamp)
            ? ReplicationStepRelation.replay
            : ReplicationStepRelation.stateMismatch;
    }

    if (incoming < current)
        return ReplicationStepRelation.stale;

    if (current < maximumReplicationSequence &&
        incoming == current + 1)
        return ReplicationStepRelation.next;

    return ReplicationStepRelation.gap;
}

/**
 * Apply one decoded replication step to an editable store.
 *
 * The complete document is validated/staged before any store mutation. Object
 * chains are evaluated by OSM version, not XML action-group order. Local M18
 * conflicts are previewed before reconcileAuthoritative is called; therefore a
 * localConflict result leaves the store and checkpoint unchanged.
 *
 * Same-sequence replay succeeds as a no-op. Stale/gapped sequences fail
 * explicitly. A successfully applied next sequence advances only the returned
 * checkpoint; durable persistence remains the caller's responsibility.
 */
bool applyReplicationStep(
    OsmStore store,
    scope ref const ReplicationCheckpoint checkpoint,
    scope ref const ReplicationFeed feed,
    scope ref const ReplicationState candidate,
    scope ref const OsmChangeDocument document,
    out ReplicationApplyResult result,
    out ReplicationApplyStatus status) @safe
{
    result = ReplicationApplyResult.init;
    result.checkpoint = checkpoint;
    status = ReplicationApplyStatus.init;

    if (store is null)
    {
        status.error = ReplicationApplyError.nullStore;
        return false;
    }
    if (!feed.valid)
    {
        status.error = ReplicationApplyError.invalidFeed;
        return false;
    }
    if (!checkpoint.valid)
    {
        status.error = ReplicationApplyError.invalidCheckpoint;
        return false;
    }

    final switch (classifyReplicationStep(checkpoint, feed, candidate))
    {
        case ReplicationStepRelation.next:
            break;

        case ReplicationStepRelation.replay:
            result.sequenceReplay = true;
            return true;

        case ReplicationStepRelation.stale:
            status.error = ReplicationApplyError.staleSequence;
            return false;

        case ReplicationStepRelation.gap:
            status.error = ReplicationApplyError.sequenceGap;
            return false;

        case ReplicationStepRelation.feedMismatch:
            status.error = ReplicationApplyError.feedMismatch;
            return false;

        case ReplicationStepRelation.stateMismatch:
            status.error = ReplicationApplyError.stateMismatch;
            return false;

        case ReplicationStepRelation.invalid:
            status.error = ReplicationApplyError.invalidCheckpoint;
            return false;
    }

    result.inputEntries = document.changes.entries.length;

    OwnedChangeEntry[][OsmId] nodeChains;
    OwnedChangeEntry[][OsmId] wayChains;
    OwnedChangeEntry[][OsmId] relationChains;
    OsmId[] nodeIds;
    OsmId[] wayIds;
    OsmId[] relationIds;

    foreach (i, ref const entry; document.changes.entries)
    {
        status.entryIndex = i;
        status.type = entry.type;
        status.id = entry.id;
        status.incomingVersion = entry.metadata.versionNumber;

        if (!validReplicationEntry(entry))
        {
            status.error = ReplicationApplyError.invalidChangeEntry;
            return false;
        }

        final switch (entry.type)
        {
            case ElementType.node:
                appendChain(nodeChains, nodeIds, entry);
                break;
            case ElementType.way:
                appendChain(wayChains, wayIds, entry);
                break;
            case ElementType.relation:
                appendChain(relationChains, relationIds, entry);
                break;
        }
    }

    sort(nodeIds);
    sort(wayIds);
    sort(relationIds);

    AuthoritativeBatch authoritative;

    foreach (id; nodeIds)
    {
        NodeState base;
        NodeState local;
        NodeState remote;
        OsmHandle ignored;
        store.syncNodeStates(id, ignored, base, local);

        auto chain = nodeChains[id];
        sortChain(chain);
        if (!stageNodeChain(
                base,
                chain,
                remote,
                result,
                status))
            return false;

        if (!sameNodeState(base, remote))
        {
            previewNode(base, local, remote, result, status);
            authoritative.nodes ~= remote.deepCopy();
            ++result.stagedIdentities;
        }
    }

    foreach (id; wayIds)
    {
        WayState base;
        WayState local;
        WayState remote;
        OsmHandle ignored;
        store.syncWayStates(id, ignored, base, local);

        auto chain = wayChains[id];
        sortChain(chain);
        if (!stageWayChain(
                base,
                chain,
                remote,
                result,
                status))
            return false;

        if (!sameWayState(base, remote))
        {
            previewWay(base, local, remote, result, status);
            authoritative.ways ~= remote.deepCopy();
            ++result.stagedIdentities;
        }
    }

    foreach (id; relationIds)
    {
        RelationState base;
        RelationState local;
        RelationState remote;
        OsmHandle ignored;
        store.syncRelationStates(id, ignored, base, local);

        auto chain = relationChains[id];
        sortChain(chain);
        if (!stageRelationChain(
                base,
                chain,
                remote,
                result,
                status))
            return false;

        if (!sameRelationState(base, remote))
        {
            previewRelation(base, local, remote, result, status);
            authoritative.relations ~= remote.deepCopy();
            ++result.stagedIdentities;
        }
    }

    // No conflict is allowed to reach mutation: callers may resolve local work
    // and replay exactly the same sequence against the old checkpoint.
    if (result.conflicts.length != 0)
    {
        status.error = ReplicationApplyError.localConflict;
        return false;
    }

    ReconcileStatus reconcileStatus;
    if (!reconcileAuthoritative(
            store,
            authoritative,
            result.reconciliation,
            reconcileStatus))
    {
        status.error = ReplicationApplyError.reconcileFailure;
        status.reconcileStatus = reconcileStatus;
        return false;
    }

    // Defensive assertion of the M18 preview/reconcile composition.
    if (result.reconciliation.requiresResolution)
    {
        status.error = ReplicationApplyError.reconcileFailure;
        return false;
    }

    result.checkpoint.feed = copyFeed(feed);
    result.checkpoint.state = candidate;
    result.checkpointAdvanced = true;
    status = ReplicationApplyStatus.init;
    return true;
}


/**
 * Resource and parser limits for one compressed replication change resource.
 *
 * Zero compressedBufferSize selects 64 KiB. Zero maximumCompressedBytes and
 * maximumDecodedBytes disable those explicit absolute limits. A zero expansion
 * ratio disables the ratio bound.
 */
struct ReplicationIngestOptions
{
    size_t compressedBufferSize;
    ulong maximumCompressedBytes;
    ulong maximumDecodedBytes;
    ulong maximumExpansionRatio;
    OsmChangeReadOptions osmChange;
}

/** Stable failure stage for compressed replication ingestion. */
enum ReplicationIngestError : ubyte
{
    none,
    nullSource,
    resourceLimit,
    transportFailure,
    compressionFailure,
    osmChangeFailure,
    applyFailure,
}

/**
 * Diagnostic for one compressed replication ingestion attempt.
 *
 * Provider-specific diagnostics are retained so callers can distinguish a
 * transport read failure from a GZIP integrity/limit failure, XML/osmChange
 * rejection, or semantic replication-apply failure.
 */
struct ReplicationIngestStatus
{
    ReplicationIngestError error = ReplicationIngestError.none;
    ReadError transportError = ReadError.none;
    DecodeError compressionError;
    OsmChangeReadStatus osmChangeStatus;
    ReplicationApplyStatus applyStatus;
    ulong compressedBytesRead;
    ulong decodedBytes;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == ReplicationIngestError.none;
    }
}

/**
 * Decode, parse and transactionally apply one GZIP-compressed replication step.
 *
 * The compressed resource is read through transport-d in bounded chunks and
 * decoded with compression-d's stable streaming GZIP contract. Decoded XML
 * bytes are never materialized as a complete buffer: the existing osmChange
 * reader consumes them through an internal absolute-offset ByteSource adapter.
 *
 * The osmChange semantic document is still materialized before store mutation,
 * matching applyReplicationStep's M19 transaction boundary. GZIP CRC-32/ISIZE,
 * concatenated-member completion and trailing-garbage checks must all succeed
 * before the document can reach applyReplicationStep.
 *
 * The compressed ByteSource must describe a stable resource for the duration
 * of this call. Generic retrieval, retries, scheduling and durable checkpoint
 * persistence remain caller responsibilities.
 */
bool applyGzipReplicationStep(
    OsmStore store,
    ByteSource compressedChange,
    scope ref const ReplicationCheckpoint checkpoint,
    scope ref const ReplicationFeed feed,
    scope ref const ReplicationState candidate,
    out ReplicationApplyResult result,
    out ReplicationIngestStatus status,
    ReplicationIngestOptions options = ReplicationIngestOptions.init) @safe
{
    result = ReplicationApplyResult.init;
    result.checkpoint = checkpoint;
    status = ReplicationIngestStatus.init;

    if (compressedChange is null)
    {
        status.error = ReplicationIngestError.nullSource;
        return false;
    }

    DecodeLimits limits;
    limits.maxOutputBytes = options.maximumDecodedBytes == 0
        ? ulong.max
        : options.maximumDecodedBytes;
    limits.maxExpansionRatio = options.maximumExpansionRatio;

    auto decoded = new GzipDecodedSource(
        compressedChange,
        options.compressedBufferSize,
        options.maximumCompressedBytes,
        limits);

    OsmChangeDocument document;
    OsmChangeReadStatus readStatus;
    if (!readOsmChangeDocument(
            decoded,
            document,
            readStatus,
            options.osmChange))
    {
        status.osmChangeStatus = readStatus;
        captureIngestProgress(decoded, status);

        const provider = decoded.status;
        if (!provider.ok)
        {
            mapGzipSourceFailure(provider, status);
            return false;
        }

        if (readStatus.error == OsmChangeReadError.transportFailure)
        {
            status.error = ReplicationIngestError.transportFailure;
            status.transportError = readStatus.transportError;
            return false;
        }

        status.error = ReplicationIngestError.osmChangeFailure;
        return false;
    }

    // Defensive completion check: semantic success may never bypass trailer
    // validation. In normal dxml operation its final empty probe has already
    // forced this state.
    if (!decoded.finishValidation())
    {
        captureIngestProgress(decoded, status);

        const provider = decoded.status;
        if (!provider.ok)
        {
            mapGzipSourceFailure(provider, status);
            return false;
        }

        status.error = ReplicationIngestError.osmChangeFailure;
        status.osmChangeStatus.error =
            OsmChangeReadError.invalidStructure;
        return false;
    }

    captureIngestProgress(decoded, status);

    ReplicationApplyStatus applyStatus;
    if (!applyReplicationStep(
            store,
            checkpoint,
            feed,
            candidate,
            document,
            result,
            applyStatus))
    {
        status.error = ReplicationIngestError.applyFailure;
        status.applyStatus = applyStatus;
        return false;
    }

    return true;
}

private void captureIngestProgress(
    GzipDecodedSource decoded,
    ref ReplicationIngestStatus status) @safe
{
    status.compressedBytesRead = decoded.compressedBytesRead;
    status.decodedBytes = decoded.decodedBytes;
}

private void mapGzipSourceFailure(
    GzipSourceStatus provider,
    ref ReplicationIngestStatus status)
    @safe pure nothrow @nogc
{
    final switch (provider.failure)
    {
        case GzipSourceFailure.none:
            status.error = ReplicationIngestError.compressionFailure;
            break;

        case GzipSourceFailure.transport:
            status.error = ReplicationIngestError.transportFailure;
            status.transportError = provider.transportError;
            break;

        case GzipSourceFailure.compression:
            status.error = ReplicationIngestError.compressionFailure;
            status.compressionError = provider.compressionError;
            break;

        case GzipSourceFailure.compressedLimit:
            status.error = ReplicationIngestError.resourceLimit;
            break;

        case GzipSourceFailure.invalidOffset:
            status.error = ReplicationIngestError.osmChangeFailure;
            status.osmChangeStatus.error =
                OsmChangeReadError.invalidStructure;
            break;
    }
}


private:

enum size_t defaultStateMaximumBytes = 1024 * 1024;
enum size_t defaultStateChunkSize = 4096;

bool readStateBytes(
    ByteSource source,
    out ubyte[] bytes,
    ref ReplicationStateReadStatus status,
    ReplicationStateReadOptions options) @safe
{
    bytes = null;

    const maximum = options.maximumBytes == 0
        ? defaultStateMaximumBytes
        : options.maximumBytes;
    const chunkSize = options.chunkSize == 0
        ? defaultStateChunkSize
        : options.chunkSize;

    if (maximum == 0 || chunkSize == 0)
    {
        status.error = ReplicationStateReadError.resourceLimit;
        return false;
    }

    auto chunk = new ubyte[chunkSize];
    ulong offset;

    while (bytes.length < maximum)
    {
        auto request = maximum - bytes.length;
        if (request > chunk.length)
            request = chunk.length;

        auto read = source.readSome(offset, chunk[0 .. request]);
        if (read.hasError)
        {
            if (read.error.kind == ReadError.endOfSource)
                return true;

            status.error = read.error.kind == ReadError.limitExceeded
                ? ReplicationStateReadError.resourceLimit
                : ReplicationStateReadError.transportFailure;
            status.transportError = read.error.kind;
            return false;
        }

        const count = read.value.bytesRead;
        if (count == 0)
            return true;

        bytes ~= chunk[0 .. count];
        offset += count;

        if (count < request)
            return true;
    }

    ubyte[1] probe;
    auto extra = source.readSome(offset, probe[]);
    if (extra.hasError && extra.error.kind == ReadError.endOfSource)
        return true;

    if (extra.hasValue && extra.value.bytesRead == 0)
        return true;

    if (extra.hasError)
    {
        status.error = extra.error.kind == ReadError.limitExceeded
            ? ReplicationStateReadError.resourceLimit
            : ReplicationStateReadError.transportFailure;
        status.transportError = extra.error.kind;
        return false;
    }

    status.error = ReplicationStateReadError.resourceLimit;
    return false;
}

bool asciiText(scope const(ubyte)[] bytes, out string text) @safe
{
    text = null;
    char[] chars;
    chars.length = bytes.length;
    foreach (i, value; bytes)
    {
        if (value > 0x7f)
            return false;
        chars[i] = cast(char)value;
    }
    text = chars.idup;
    return true;
}

const(char)[] trimAscii(scope const(char)[] value)
    @safe pure nothrow @nogc
{
    size_t first;
    size_t last = value.length;

    while (first < last &&
           (value[first] == ' ' || value[first] == '\t'))
        ++first;
    while (last > first &&
           (value[last - 1] == ' ' || value[last - 1] == '\t'))
        --last;

    return value[first .. last];
}

bool parseSequence(
    scope const(char)[] value,
    out ulong sequence) @safe pure nothrow @nogc
{
    sequence = 0;
    if (value.length == 0)
        return false;

    foreach (ch; value)
    {
        if (ch < '0' || ch > '9')
            return false;
        const digit = cast(ulong)(ch - '0');
        if (sequence >
            (maximumReplicationSequence - digit) / 10)
            return false;
        sequence = sequence * 10 + digit;
    }
    return sequence <= maximumReplicationSequence;
}

bool parseReplicationTimestamp(
    scope const(char)[] encoded,
    out ReplicationTimestamp timestamp) @safe
{
    timestamp = ReplicationTimestamp.init;

    char[] normalized;
    normalized.reserve(encoded.length);

    for (size_t i; i < encoded.length; ++i)
    {
        const ch = encoded[i];
        if (ch != '\\')
        {
            normalized ~= ch;
            continue;
        }

        if (i + 1 >= encoded.length)
            return false;

        const escaped = encoded[++i];
        if (escaped != ':' && escaped != '\\')
            return false;
        normalized ~= escaped;
    }

    if (normalized.length != 20 ||
        normalized[4] != '-' ||
        normalized[7] != '-' ||
        normalized[10] != 'T' ||
        normalized[13] != ':' ||
        normalized[16] != ':' ||
        normalized[19] != 'Z')
        return false;

    int year;
    int month;
    int day;
    int hour;
    int minute;
    int second;

    if (!parseFixedDecimal(normalized[0 .. 4], year) ||
        !parseFixedDecimal(normalized[5 .. 7], month) ||
        !parseFixedDecimal(normalized[8 .. 10], day) ||
        !parseFixedDecimal(normalized[11 .. 13], hour) ||
        !parseFixedDecimal(normalized[14 .. 16], minute) ||
        !parseFixedDecimal(normalized[17 .. 19], second))
        return false;

    if (year < 1 ||
        month < 1 || month > 12 ||
        day < 1 || day > daysInMonth(year, month) ||
        hour < 0 || hour > 23 ||
        minute < 0 || minute > 59 ||
        second < 0 || second > 59)
        return false;

    const days = daysFromCivil(year, month, day);
    timestamp.hasValue = true;
    timestamp.unixSeconds =
        days * 86_400L +
        cast(long)hour * 3_600L +
        cast(long)minute * 60L +
        second;
    timestamp.isoUtc = normalized.idup;
    return true;
}

bool parseFixedDecimal(
    scope const(char)[] value,
    out int parsed) @safe pure nothrow @nogc
{
    parsed = 0;
    if (value.length == 0)
        return false;

    foreach (ch; value)
    {
        if (ch < '0' || ch > '9')
            return false;
        parsed = parsed * 10 + cast(int)(ch - '0');
    }
    return true;
}

int daysInMonth(int year, int month) @safe pure nothrow @nogc
{
    static immutable int[12] ordinary =
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

    if (month == 2 && isLeapYear(year))
        return 29;
    return ordinary[month - 1];
}

bool isLeapYear(int year) @safe pure nothrow @nogc
{
    return year % 4 == 0 &&
        (year % 100 != 0 || year % 400 == 0);
}

// Howard Hinnant's civil-calendar transform, shifted to Unix epoch days.
long daysFromCivil(int year, int month, int day)
    @safe pure nothrow @nogc
{
    long y = year;
    const long m = month;
    const long d = day;
    y -= m <= 2 ? 1 : 0;
    const long era = (y >= 0 ? y : y - 399) / 400;
    const long yoe = y - era * 400;
    const long mp = m + (m > 2 ? -3 : 9);
    const long doy = (153 * mp + 2) / 5 + d - 1;
    const long doe =
        yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146_097 + doe - 719_468;
}

bool sameFeed(
    scope ref const ReplicationFeed a,
    scope ref const ReplicationFeed b)
    @safe pure nothrow @nogc
{
    return a.granularity == b.granularity && a.id == b.id;
}

bool sameTimestamp(
    scope ref const ReplicationTimestamp a,
    scope ref const ReplicationTimestamp b)
    @safe pure nothrow @nogc
{
    return a.hasValue == b.hasValue &&
           (!a.hasValue || a.unixSeconds == b.unixSeconds);
}

ReplicationFeed copyFeed(scope ref const ReplicationFeed source) @safe
{
    ReplicationFeed result;
    result.id = source.id.idup;
    result.granularity = source.granularity;
    return result;
}

bool validReplicationEntry(scope ref const OwnedChangeEntry entry)
    @safe pure nothrow @nogc
{
    if (!entry.shapeValid ||
        entry.id <= 0 ||
        !entry.metadata.hasVersion ||
        entry.metadata.versionNumber <= 0)
        return false;

    if (entry.action != ChangeAction.deleteObject &&
        entry.objectState != ChangeObjectState.complete)
        return false;

    if (entry.action == ChangeAction.create &&
        entry.metadata.versionNumber != 1)
        return false;

    return true;
}

void appendChain(
    ref OwnedChangeEntry[][OsmId] chains,
    ref OsmId[] ids,
    scope ref const OwnedChangeEntry entry) @safe
{
    if (entry.id !in chains)
        ids ~= entry.id;
    chains[entry.id] ~= entry.deepCopy();
}

void sortChain(ref OwnedChangeEntry[] chain) @safe
{
    foreach (i; 1 .. chain.length)
    {
        auto value = chain[i];
        size_t j = i;
        while (j > 0 &&
               chain[j - 1].metadata.versionNumber >
                   value.metadata.versionNumber)
        {
            chain[j] = chain[j - 1];
            --j;
        }
        chain[j] = value;
    }
}

bool stageNodeChain(
    NodeState base,
    scope const(OwnedChangeEntry)[] chain,
    out NodeState remote,
    ref ReplicationApplyResult result,
    ref ReplicationApplyStatus status) @safe
{
    remote = base.deepCopy();
    foreach (i, ref const entry; chain)
    {
        status.entryIndex = i;
        status.type = ElementType.node;
        status.id = entry.id;
        status.incomingVersion = entry.metadata.versionNumber;
        status.knownVersion =
            remote.hasVersion ? remote.versionNumber : 0;

        NodeState candidate;
        if (!nodeStateFromEntry(entry, candidate))
        {
            status.error = ReplicationApplyError.invalidChangeEntry;
            return false;
        }

        const decision = transitionDecision(
            remote.exists,
            remote.hasVersion,
            remote.versionNumber,
            entry);

        final switch (decision)
        {
            case TransitionDecision.apply:
                remote = candidate;
                ++result.stagedTransitions;
                break;
            case TransitionDecision.replay:
                if (!sameNodeState(remote, candidate))
                {
                    status.error = ReplicationApplyError.payloadMismatch;
                    return false;
                }
                ++result.replayedEntries;
                break;
            case TransitionDecision.stale:
                ++result.staleEntries;
                break;
            case TransitionDecision.unknownBaseline:
                status.error = ReplicationApplyError.unknownBaseline;
                return false;
            case TransitionDecision.invalidTransition:
                status.error = ReplicationApplyError.invalidTransition;
                return false;
            case TransitionDecision.versionGap:
                status.error = ReplicationApplyError.versionGap;
                return false;
        }
    }
    return true;
}

bool stageWayChain(
    WayState base,
    scope const(OwnedChangeEntry)[] chain,
    out WayState remote,
    ref ReplicationApplyResult result,
    ref ReplicationApplyStatus status) @safe
{
    remote = base.deepCopy();
    foreach (i, ref const entry; chain)
    {
        status.entryIndex = i;
        status.type = ElementType.way;
        status.id = entry.id;
        status.incomingVersion = entry.metadata.versionNumber;
        status.knownVersion =
            remote.hasVersion ? remote.versionNumber : 0;

        WayState candidate;
        if (!wayStateFromEntry(entry, candidate))
        {
            status.error = ReplicationApplyError.invalidChangeEntry;
            return false;
        }

        const decision = transitionDecision(
            remote.exists,
            remote.hasVersion,
            remote.versionNumber,
            entry);

        final switch (decision)
        {
            case TransitionDecision.apply:
                remote = candidate;
                ++result.stagedTransitions;
                break;
            case TransitionDecision.replay:
                if (!sameWayState(remote, candidate))
                {
                    status.error = ReplicationApplyError.payloadMismatch;
                    return false;
                }
                ++result.replayedEntries;
                break;
            case TransitionDecision.stale:
                ++result.staleEntries;
                break;
            case TransitionDecision.unknownBaseline:
                status.error = ReplicationApplyError.unknownBaseline;
                return false;
            case TransitionDecision.invalidTransition:
                status.error = ReplicationApplyError.invalidTransition;
                return false;
            case TransitionDecision.versionGap:
                status.error = ReplicationApplyError.versionGap;
                return false;
        }
    }
    return true;
}

bool stageRelationChain(
    RelationState base,
    scope const(OwnedChangeEntry)[] chain,
    out RelationState remote,
    ref ReplicationApplyResult result,
    ref ReplicationApplyStatus status) @safe
{
    remote = base.deepCopy();
    foreach (i, ref const entry; chain)
    {
        status.entryIndex = i;
        status.type = ElementType.relation;
        status.id = entry.id;
        status.incomingVersion = entry.metadata.versionNumber;
        status.knownVersion =
            remote.hasVersion ? remote.versionNumber : 0;

        RelationState candidate;
        if (!relationStateFromEntry(entry, candidate))
        {
            status.error = ReplicationApplyError.invalidChangeEntry;
            return false;
        }

        const decision = transitionDecision(
            remote.exists,
            remote.hasVersion,
            remote.versionNumber,
            entry);

        final switch (decision)
        {
            case TransitionDecision.apply:
                remote = candidate;
                ++result.stagedTransitions;
                break;
            case TransitionDecision.replay:
                if (!sameRelationState(remote, candidate))
                {
                    status.error = ReplicationApplyError.payloadMismatch;
                    return false;
                }
                ++result.replayedEntries;
                break;
            case TransitionDecision.stale:
                ++result.staleEntries;
                break;
            case TransitionDecision.unknownBaseline:
                status.error = ReplicationApplyError.unknownBaseline;
                return false;
            case TransitionDecision.invalidTransition:
                status.error = ReplicationApplyError.invalidTransition;
                return false;
            case TransitionDecision.versionGap:
                status.error = ReplicationApplyError.versionGap;
                return false;
        }
    }
    return true;
}

enum TransitionDecision : ubyte
{
    apply,
    replay,
    stale,
    unknownBaseline,
    invalidTransition,
    versionGap,
}

TransitionDecision transitionDecision(
    bool previousExists,
    bool previousHasVersion,
    int previousVersion,
    scope ref const OwnedChangeEntry entry)
    @safe pure nothrow @nogc
{
    const incoming = entry.metadata.versionNumber;

    if (previousHasVersion)
    {
        if (incoming < previousVersion)
            return TransitionDecision.stale;
        if (incoming == previousVersion)
            return TransitionDecision.replay;
        if (incoming != previousVersion + 1)
            return TransitionDecision.versionGap;

        final switch (entry.action)
        {
            case ChangeAction.create:
                return TransitionDecision.invalidTransition;

            case ChangeAction.modify:
                return entry.objectState == ChangeObjectState.complete
                    ? TransitionDecision.apply
                    : TransitionDecision.invalidTransition;

            case ChangeAction.deleteObject:
                return previousExists
                    ? TransitionDecision.apply
                    : TransitionDecision.invalidTransition;
        }
    }

    if (previousExists)
        return TransitionDecision.unknownBaseline;

    if (entry.action == ChangeAction.create &&
        incoming == 1 &&
        entry.objectState == ChangeObjectState.complete)
        return TransitionDecision.apply;

    return TransitionDecision.unknownBaseline;
}

bool nodeStateFromEntry(
    scope ref const OwnedChangeEntry entry,
    out NodeState state) @safe
{
    if (entry.type != ElementType.node)
        return false;

    if (entry.action == ChangeAction.deleteObject)
    {
        state = NodeState.absent(
            entry.id,
            entry.metadata.versionNumber);
        return true;
    }

    if (entry.objectState != ChangeObjectState.complete)
        return false;

    OwnedNode value;
    value.id = entry.id;
    value.metadata = entry.metadata;
    value.location = entry.location;
    value.tags = entry.tags.dup;
    state = NodeState.present(value);
    return true;
}

bool wayStateFromEntry(
    scope ref const OwnedChangeEntry entry,
    out WayState state) @safe
{
    if (entry.type != ElementType.way)
        return false;

    if (entry.action == ChangeAction.deleteObject)
    {
        state = WayState.absent(
            entry.id,
            entry.metadata.versionNumber);
        return true;
    }

    if (entry.objectState != ChangeObjectState.complete)
        return false;

    OwnedWay value;
    value.id = entry.id;
    value.metadata = entry.metadata;
    value.tags = entry.tags.dup;
    value.nodes = entry.wayNodes.dup;
    state = WayState.present(value);
    return true;
}

bool relationStateFromEntry(
    scope ref const OwnedChangeEntry entry,
    out RelationState state) @safe
{
    if (entry.type != ElementType.relation)
        return false;

    if (entry.action == ChangeAction.deleteObject)
    {
        state = RelationState.absent(
            entry.id,
            entry.metadata.versionNumber);
        return true;
    }

    if (entry.objectState != ChangeObjectState.complete)
        return false;

    OwnedRelation value;
    value.id = entry.id;
    value.metadata = entry.metadata;
    value.tags = entry.tags.dup;
    value.members = entry.relationMembers.dup;
    state = RelationState.present(value);
    return true;
}

void previewNode(
    NodeState base,
    NodeState local,
    NodeState remote,
    ref ReplicationApplyResult result,
    ref ReplicationApplyStatus status) @safe
{
    auto report = classifyConflict(base, local, remote);
    if (!report.requiresResolution)
        return;

    result.conflicts ~= report;
    if (status.error == ReplicationApplyError.none)
    {
        status.type = ElementType.node;
        status.id = remote.id;
        status.error = ReplicationApplyError.localConflict;
    }
}

void previewWay(
    WayState base,
    WayState local,
    WayState remote,
    ref ReplicationApplyResult result,
    ref ReplicationApplyStatus status) @safe
{
    auto report = classifyConflict(base, local, remote);
    if (!report.requiresResolution)
        return;

    result.conflicts ~= report;
    if (status.error == ReplicationApplyError.none)
    {
        status.type = ElementType.way;
        status.id = remote.id;
        status.error = ReplicationApplyError.localConflict;
    }
}

void previewRelation(
    RelationState base,
    RelationState local,
    RelationState remote,
    ref ReplicationApplyResult result,
    ref ReplicationApplyStatus status) @safe
{
    auto report = classifyConflict(base, local, remote);
    if (!report.requiresResolution)
        return;

    result.conflicts ~= report;
    if (status.error == ReplicationApplyError.none)
    {
        status.type = ElementType.relation;
        status.id = remote.id;
        status.error = ReplicationApplyError.localConflict;
    }
}

bool sameNodeState(NodeState a, NodeState b) @safe
{
    if (a.exists != b.exists ||
        a.hasVersion != b.hasVersion ||
        a.versionNumber != b.versionNumber ||
        a.id != b.id)
        return false;

    if (!a.exists)
        return true;

    auto report = classifyConflict(a, a, b);
    return report.disposition == ConflictDisposition.unchanged;
}

bool sameWayState(WayState a, WayState b) @safe
{
    if (a.exists != b.exists ||
        a.hasVersion != b.hasVersion ||
        a.versionNumber != b.versionNumber ||
        a.id != b.id)
        return false;

    if (!a.exists)
        return true;

    auto report = classifyConflict(a, a, b);
    return report.disposition == ConflictDisposition.unchanged;
}

bool sameRelationState(RelationState a, RelationState b) @safe
{
    if (a.exists != b.exists ||
        a.hasVersion != b.hasVersion ||
        a.versionNumber != b.versionNumber ||
        a.id != b.id)
        return false;

    if (!a.exists)
        return true;

    auto report = classifyConflict(a, a, b);
    return report.disposition == ConflictDisposition.unchanged;
}

unittest
{
    import transport.source : MemorySource;

    enum stateText =
        "sequenceNumber=123456\n" ~
        "timestamp=2026-11-08T15\\:40\\:00Z\n" ~
        "txnMax=123\n";

    auto source = new MemorySource(cast(const(ubyte)[]) stateText);
    ReplicationState state;
    ReplicationStateReadStatus status;
    assert(readReplicationState(source, state, status));
    assert(state.sequenceNumber == 123456);
    assert(state.timestamp.isoUtc == "2026-11-08T15:40:00Z");

    ReplicationResourcePaths paths;
    ReplicationPathStatus pathStatus;
    assert(replicationResourcePaths(51_123, paths, pathStatus));
    assert(paths.change == "000/051/123.osc.gz");
    assert(paths.state == "000/051/123.state.txt");
}
