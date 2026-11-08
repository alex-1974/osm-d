/**
 * Authoritative server refresh and editable-store reconciliation.
 *
 * Remote values are supplied by the caller; this module performs no network
 * access. The batch is fully validated and classified before the first visible
 * store mutation. Conflicting/local-only objects remain untouched.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-08
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.reconcile.authoritative;

import osm.model.conflict :
    ConflictDisposition,
    ConflictReport,
    NodeState,
    RelationState,
    WayState,
    classifyConflict;
import osm.model.owned :
    OwnedNode,
    OwnedRelation,
    OwnedWay;
import osm.store.compact.store :
    OsmHandle,
    OsmStore,
    StoreError,
    StoreStatus;
import osm.view.element :
    ElementType,
    OsmId;

/**
 * Authoritative current states to reconcile.
 *
 * A present state carries one complete current server object. An absent state
 * explicitly means that the authoritative source proved that identity absent
 * (for example Editing API 410). Omitted identities are not touched.
 */
struct AuthoritativeBatch
{
    NodeState[] nodes;
    WayState[] ways;
    RelationState[] relations;

    @property size_t length() const @safe pure nothrow @nogc
    {
        return nodes.length + ways.length + relations.length;
    }

    @property bool empty() const @safe pure nothrow @nogc
    {
        return length == 0;
    }
}

/** Result of one identity within an authoritative reconciliation batch. */
enum ReconcileAction : ubyte
{
    unchanged,
    inserted,
    refreshed,
    removed,
    keptLocal,
    deferredConcurrent,
    conflict,
}

/** Deterministic per-identity reconciliation fact. */
struct ReconcileEntry
{
    ElementType type;
    OsmId id;
    ReconcileAction action;
    ConflictReport conflict;

    @property bool mutatedStore() const @safe pure nothrow @nogc
    {
        return action == ReconcileAction.inserted ||
               action == ReconcileAction.refreshed ||
               action == ReconcileAction.removed;
    }

    @property bool requiresResolution() const @safe pure nothrow @nogc
    {
        return action == ReconcileAction.deferredConcurrent ||
               action == ReconcileAction.conflict;
    }
}

/** Aggregate reconciliation result. */
struct ReconcileResult
{
    ReconcileEntry[] entries;

    size_t inserted;
    size_t refreshed;
    size_t removed;
    size_t keptLocal;
    size_t deferred;
    size_t conflicts;

    @property bool hasConflicts() const @safe pure nothrow @nogc
    {
        return conflicts != 0;
    }

    @property bool requiresResolution() const @safe pure nothrow @nogc
    {
        return conflicts != 0 || deferred != 0;
    }
}

/** Failure before any visible batch mutation. */
enum ReconcileError : ubyte
{
    none,
    nullStore,
    invalidAuthoritativeState,
    duplicateIdentity,
    storePreflight,
}

/** Diagnostic for a rejected reconciliation batch. */
struct ReconcileStatus
{
    ReconcileError error = ReconcileError.none;
    ElementType type;
    OsmId id;
    size_t index;
    StoreStatus storeStatus;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == ReconcileError.none;
    }
}

/**
 * Reconcile authoritative states into an editable store.
 *
 * Semantics:
 * - clean/local-unchanged objects refresh to newer remote state;
 * - remote inserts are added as clean authoritative objects;
 * - authoritative deletion of a clean object removes it without creating a
 *   local deletion upload;
 * - local-only edits/deletes remain untouched;
 * - identical concurrent edits are accepted as authoritative and become clean;
 * - independent concurrent edits are reported but not auto-merged;
 * - hard conflicts/baseline mismatches are reported and remain untouched.
 *
 * All representation validation, duplicate detection and conflict
 * classification complete before the first visible store mutation. After that
 * preflight, planned store operations are expected to be infallible except for
 * normal allocation failure; an internal invariant failure is asserted rather
 * than returned after a partial batch mutation.
 */
bool reconcileAuthoritative(
    OsmStore store,
    scope ref const AuthoritativeBatch authoritative,
    out ReconcileResult result,
    out ReconcileStatus status) @safe
{
    result = ReconcileResult.init;
    status = ReconcileStatus.init;

    if (store is null)
    {
        status.error = ReconcileError.nullStore;
        return false;
    }

    NodePlan[] nodePlans;
    WayPlan[] wayPlans;
    RelationPlan[] relationPlans;

    bool[OsmId] nodeIds;
    bool[OsmId] wayIds;
    bool[OsmId] relationIds;

    foreach (i, ref const remote; authoritative.nodes)
    {
        status.index = i;
        status.type = ElementType.node;
        status.id = remote.id;

        if (!validateRemoteState(remote, status) ||
            !claimIdentity(nodeIds, remote.id, status))
            return false;

        NodePlan plan;
        plan.remote = remote.deepCopy();
        store.syncNodeStates(
            remote.id,
            plan.handle,
            plan.base,
            plan.local);
        plan.report = classifyConflict(
            plan.base,
            plan.local,
            plan.remote);
        plan.action = actionFor(plan.report, plan.handle.valid);
        nodePlans ~= plan;
    }

    foreach (i, ref const remote; authoritative.ways)
    {
        status.index = i;
        status.type = ElementType.way;
        status.id = remote.id;

        if (!validateRemoteState(remote, status) ||
            !claimIdentity(wayIds, remote.id, status))
            return false;

        WayPlan plan;
        plan.remote = remote.deepCopy();
        store.syncWayStates(
            remote.id,
            plan.handle,
            plan.base,
            plan.local);
        plan.report = classifyConflict(
            plan.base,
            plan.local,
            plan.remote);
        plan.action = actionFor(plan.report, plan.handle.valid);
        wayPlans ~= plan;
    }

    foreach (i, ref const remote; authoritative.relations)
    {
        status.index = i;
        status.type = ElementType.relation;
        status.id = remote.id;

        if (!validateRemoteState(remote, status) ||
            !claimIdentity(relationIds, remote.id, status))
            return false;

        RelationPlan plan;
        plan.remote = remote.deepCopy();
        store.syncRelationStates(
            remote.id,
            plan.handle,
            plan.base,
            plan.local);
        plan.report = classifyConflict(
            plan.base,
            plan.local,
            plan.remote);
        plan.action = actionFor(plan.report, plan.handle.valid);
        relationPlans ~= plan;
    }

    sortPlans(nodePlans);
    sortPlans(wayPlans);
    sortPlans(relationPlans);

    foreach (ref const plan; nodePlans)
        if (!preflightPlan(store, plan, status))
            return false;
    foreach (ref const plan; wayPlans)
        if (!preflightPlan(store, plan, status))
            return false;
    foreach (ref const plan; relationPlans)
        if (!preflightPlan(store, plan, status))
            return false;

    status = ReconcileStatus.init;

    foreach (ref plan; nodePlans)
        applyPlan(store, plan, result);
    foreach (ref plan; wayPlans)
        applyPlan(store, plan, result);
    foreach (ref plan; relationPlans)
        applyPlan(store, plan, result);

    return true;
}

private:

struct NodePlan
{
    OsmHandle handle;
    NodeState base;
    NodeState local;
    NodeState remote;
    ConflictReport report;
    ReconcileAction action;
}

struct WayPlan
{
    OsmHandle handle;
    WayState base;
    WayState local;
    WayState remote;
    ConflictReport report;
    ReconcileAction action;
}

struct RelationPlan
{
    OsmHandle handle;
    RelationState base;
    RelationState local;
    RelationState remote;
    ConflictReport report;
    ReconcileAction action;
}

bool validateRemoteState(
    scope ref const NodeState state,
    ref ReconcileStatus status) @safe
{
    if (!basicStateValid(state))
    {
        status.error = ReconcileError.invalidAuthoritativeState;
        return false;
    }

    if (!state.exists)
        return true;

    if (state.value.id != state.id ||
        state.value.metadata.hasVersion != state.hasVersion ||
        state.value.metadata.versionNumber != state.versionNumber)
    {
        status.error = ReconcileError.invalidAuthoritativeState;
        return false;
    }

    return true;
}

bool validateRemoteState(
    scope ref const WayState state,
    ref ReconcileStatus status) @safe
{
    if (!basicStateValid(state))
    {
        status.error = ReconcileError.invalidAuthoritativeState;
        return false;
    }

    if (!state.exists)
        return true;

    if (state.value.id != state.id ||
        state.value.metadata.hasVersion != state.hasVersion ||
        state.value.metadata.versionNumber != state.versionNumber)
    {
        status.error = ReconcileError.invalidAuthoritativeState;
        return false;
    }

    return true;
}

bool validateRemoteState(
    scope ref const RelationState state,
    ref ReconcileStatus status) @safe
{
    if (!basicStateValid(state))
    {
        status.error = ReconcileError.invalidAuthoritativeState;
        return false;
    }

    if (!state.exists)
        return true;

    if (state.value.id != state.id ||
        state.value.metadata.hasVersion != state.hasVersion ||
        state.value.metadata.versionNumber != state.versionNumber)
    {
        status.error = ReconcileError.invalidAuthoritativeState;
        return false;
    }

    return true;
}

bool basicStateValid(T)(
    scope ref const T state) @safe pure nothrow @nogc
{
    if (state.id <= 0)
        return false;

    if (state.exists)
        return state.hasVersion && state.versionNumber > 0;

    return !state.hasVersion || state.versionNumber > 0;
}

bool claimIdentity(
    ref bool[OsmId] seen,
    OsmId id,
    ref ReconcileStatus status) @safe
{
    if (id in seen)
    {
        status.error = ReconcileError.duplicateIdentity;
        return false;
    }
    seen[id] = true;
    return true;
}

ReconcileAction actionFor(
    scope ref const ConflictReport report,
    bool hasStoreIdentity) @safe pure nothrow @nogc
{
    final switch (report.disposition)
    {
        case ConflictDisposition.unchanged:
            return ReconcileAction.unchanged;

        case ConflictDisposition.localOnly:
            return ReconcileAction.keptLocal;

        case ConflictDisposition.remoteOnly:
            if (report.remoteExists)
                return hasStoreIdentity
                    ? ReconcileAction.refreshed
                    : ReconcileAction.inserted;
            return hasStoreIdentity
                ? ReconcileAction.removed
                : ReconcileAction.unchanged;

        case ConflictDisposition.identicalConcurrent:
            if (report.remoteExists)
                return hasStoreIdentity
                    ? ReconcileAction.refreshed
                    : ReconcileAction.inserted;
            return hasStoreIdentity
                ? ReconcileAction.removed
                : ReconcileAction.unchanged;

        case ConflictDisposition.bothDeleted:
            return hasStoreIdentity
                ? ReconcileAction.removed
                : ReconcileAction.unchanged;

        case ConflictDisposition.concurrentIndependent:
            return ReconcileAction.deferredConcurrent;

        case ConflictDisposition.conflict:
        case ConflictDisposition.baselineMismatch:
            return ReconcileAction.conflict;
    }
}

bool preflightPlan(
    OsmStore store,
    scope ref const NodePlan plan,
    ref ReconcileStatus status) @safe
{
    status.type = ElementType.node;
    status.id = plan.remote.id;

    if (!plan.remote.exists ||
        (plan.action != ReconcileAction.inserted &&
         plan.action != ReconcileAction.refreshed))
        return true;

    StoreStatus storeStatus;
    if (!store.preflightAuthoritative(plan.remote.value, storeStatus))
    {
        status.error = ReconcileError.storePreflight;
        status.storeStatus = storeStatus;
        return false;
    }
    return true;
}

bool preflightPlan(
    OsmStore store,
    scope ref const WayPlan plan,
    ref ReconcileStatus status) @safe
{
    status.type = ElementType.way;
    status.id = plan.remote.id;

    if (!plan.remote.exists ||
        (plan.action != ReconcileAction.inserted &&
         plan.action != ReconcileAction.refreshed))
        return true;

    StoreStatus storeStatus;
    if (!store.preflightAuthoritative(plan.remote.value, storeStatus))
    {
        status.error = ReconcileError.storePreflight;
        status.storeStatus = storeStatus;
        return false;
    }
    return true;
}

bool preflightPlan(
    OsmStore store,
    scope ref const RelationPlan plan,
    ref ReconcileStatus status) @safe
{
    status.type = ElementType.relation;
    status.id = plan.remote.id;

    if (!plan.remote.exists ||
        (plan.action != ReconcileAction.inserted &&
         plan.action != ReconcileAction.refreshed))
        return true;

    StoreStatus storeStatus;
    if (!store.preflightAuthoritative(plan.remote.value, storeStatus))
    {
        status.error = ReconcileError.storePreflight;
        status.storeStatus = storeStatus;
        return false;
    }
    return true;
}

void applyPlan(
    OsmStore store,
    ref NodePlan plan,
    ref ReconcileResult result) @safe
{
    StoreStatus storeStatus;
    OsmHandle handle;

    final switch (plan.action)
    {
        case ReconcileAction.unchanged:
            break;

        case ReconcileAction.inserted:
            const inserted =
                store.add(plan.remote.value, handle, storeStatus);
            assert(inserted);
            ++result.inserted;
            break;

        case ReconcileAction.refreshed:
            const refreshed = store.replaceAuthoritative(
                plan.handle, plan.remote.value, storeStatus);
            assert(refreshed);
            ++result.refreshed;
            break;

        case ReconcileAction.removed:
            const removed = store.discardAuthoritative(
                plan.handle,
                plan.remote.hasVersion
                    ? plan.remote.versionNumber
                    : 0,
                storeStatus);
            assert(removed);
            ++result.removed;
            break;

        case ReconcileAction.keptLocal:
            ++result.keptLocal;
            break;

        case ReconcileAction.deferredConcurrent:
            ++result.deferred;
            break;

        case ReconcileAction.conflict:
            ++result.conflicts;
            break;
    }

    appendResult(
        ElementType.node,
        plan.remote.id,
        plan.action,
        plan.report,
        result);
}

void applyPlan(
    OsmStore store,
    ref WayPlan plan,
    ref ReconcileResult result) @safe
{
    StoreStatus storeStatus;
    OsmHandle handle;

    final switch (plan.action)
    {
        case ReconcileAction.unchanged:
            break;

        case ReconcileAction.inserted:
            const inserted =
                store.add(plan.remote.value, handle, storeStatus);
            assert(inserted);
            ++result.inserted;
            break;

        case ReconcileAction.refreshed:
            const refreshed = store.replaceAuthoritative(
                plan.handle, plan.remote.value, storeStatus);
            assert(refreshed);
            ++result.refreshed;
            break;

        case ReconcileAction.removed:
            const removed = store.discardAuthoritative(
                plan.handle,
                plan.remote.hasVersion
                    ? plan.remote.versionNumber
                    : 0,
                storeStatus);
            assert(removed);
            ++result.removed;
            break;

        case ReconcileAction.keptLocal:
            ++result.keptLocal;
            break;

        case ReconcileAction.deferredConcurrent:
            ++result.deferred;
            break;

        case ReconcileAction.conflict:
            ++result.conflicts;
            break;
    }

    appendResult(
        ElementType.way,
        plan.remote.id,
        plan.action,
        plan.report,
        result);
}

void applyPlan(
    OsmStore store,
    ref RelationPlan plan,
    ref ReconcileResult result) @safe
{
    StoreStatus storeStatus;
    OsmHandle handle;

    final switch (plan.action)
    {
        case ReconcileAction.unchanged:
            break;

        case ReconcileAction.inserted:
            const inserted =
                store.add(plan.remote.value, handle, storeStatus);
            assert(inserted);
            ++result.inserted;
            break;

        case ReconcileAction.refreshed:
            const refreshed = store.replaceAuthoritative(
                plan.handle, plan.remote.value, storeStatus);
            assert(refreshed);
            ++result.refreshed;
            break;

        case ReconcileAction.removed:
            const removed = store.discardAuthoritative(
                plan.handle,
                plan.remote.hasVersion
                    ? plan.remote.versionNumber
                    : 0,
                storeStatus);
            assert(removed);
            ++result.removed;
            break;

        case ReconcileAction.keptLocal:
            ++result.keptLocal;
            break;

        case ReconcileAction.deferredConcurrent:
            ++result.deferred;
            break;

        case ReconcileAction.conflict:
            ++result.conflicts;
            break;
    }

    appendResult(
        ElementType.relation,
        plan.remote.id,
        plan.action,
        plan.report,
        result);
}

void appendResult(
    ElementType type,
    OsmId id,
    ReconcileAction action,
    scope ref ConflictReport conflict,
    ref ReconcileResult result) @safe
{
    ReconcileEntry entry;
    entry.type = type;
    entry.id = id;
    entry.action = action;
    entry.conflict = conflict;
    result.entries ~= entry;
}

void sortPlans(T)(ref T[] plans) @safe
{
    foreach (i; 1 .. plans.length)
    {
        auto value = plans[i];
        size_t j = i;
        while (j > 0 &&
               plans[j - 1].remote.id > value.remote.id)
        {
            plans[j] = plans[j - 1];
            --j;
        }
        plans[j] = value;
    }
}

unittest
{
    import osm.model.owned :
        OwnedMetadata,
        OwnedTag,
        ownBytes;
    import osm.view.location : LocationView;

    OwnedNode base;
    base.id = 1;
    base.metadata.hasVersion = true;
    base.metadata.versionNumber = 1;
    base.location = LocationView(10, 20);
    base.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"old"));

    auto store = new OsmStore();
    OsmHandle handle;
    StoreStatus storeStatus;
    assert(store.add(base, handle, storeStatus));

    auto remote = base.deepCopy();
    remote.metadata.versionNumber = 2;
    remote.tags[0].value =
        ownBytes(cast(const(ubyte)[])"new");

    AuthoritativeBatch batch;
    batch.nodes ~= NodeState.present(remote);

    ReconcileResult result;
    ReconcileStatus status;
    assert(reconcileAuthoritative(store, batch, result, status));
    assert(result.refreshed == 1);
    assert(result.entries[0].action == ReconcileAction.refreshed);

    OwnedNode current;
    assert(store.copyNode(handle, current, storeStatus));
    assert(current.metadata.versionNumber == 2);
    assert(current.tags[0].value ==
        cast(const(ubyte)[])"new");
}

unittest
{
    import osm.model.owned :
        OwnedTag,
        ownBytes;
    import osm.view.location : LocationView;

    OwnedNode base;
    base.id = 2;
    base.metadata.hasVersion = true;
    base.metadata.versionNumber = 5;
    base.location = LocationView(10, 20);
    base.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"base"));

    auto store = new OsmStore();
    OsmHandle handle;
    StoreStatus storeStatus;
    assert(store.add(base, handle, storeStatus));

    auto local = base.deepCopy();
    local.tags[0].value =
        ownBytes(cast(const(ubyte)[])"local");
    assert(store.replace(handle, local, storeStatus));

    auto remote = base.deepCopy();
    remote.metadata.versionNumber = 6;
    remote.tags[0].value =
        ownBytes(cast(const(ubyte)[])"remote");

    AuthoritativeBatch batch;
    batch.nodes ~= NodeState.present(remote);

    ReconcileResult result;
    ReconcileStatus status;
    assert(reconcileAuthoritative(store, batch, result, status));
    assert(result.conflicts == 1);
    assert(result.entries[0].action == ReconcileAction.conflict);

    OwnedNode current;
    assert(store.copyNode(handle, current, storeStatus));
    assert(current.tags[0].value ==
        cast(const(ubyte)[])"local");
}
