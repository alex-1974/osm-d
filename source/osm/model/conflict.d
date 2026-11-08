/**
 * Structured three-way OSM conflict classification.
 *
 * The classifier describes base/local/remote facts. It does not merge objects,
 * choose winners or contain editor UI policy.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-08
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.model.conflict;

import osm.model.owned :
    OwnedBytes,
    OwnedNode,
    OwnedNodeRef,
    OwnedRelation,
    OwnedRelationMember,
    OwnedTag,
    OwnedWay;
import osm.view.element :
    ElementType,
    OsmId;

/** Presence plus optional authoritative version for one typed element state. */
struct ElementState(T)
if (is(T == OwnedNode) || is(T == OwnedWay) || is(T == OwnedRelation))
{
    bool exists;
    OsmId id;
    bool hasVersion;
    int version;
    T value;

    /** Construct a present state from one owned element. */
    static ElementState present(T source) @safe
    {
        ElementState result;
        result.exists = true;
        result.id = source.id;
        result.hasVersion = source.metadata.hasVersion;
        result.version = source.metadata.versionNumber;
        result.value = source.deepCopy();
        return result;
    }

    /**
     * Construct an absent/deleted state.
     *
     * version may be omitted when the authoritative source only proves absence
     * (for example an Editing API 410 response).
     */
    static ElementState absent(
        OsmId id,
        int version = 0) @safe pure nothrow @nogc
    {
        ElementState result;
        result.id = id;
        result.hasVersion = version > 0;
        result.version = version;
        return result;
    }

    /// Independently mutable copy.
    ElementState deepCopy() const @safe
    {
        ElementState result = this;
        if (exists)
            result.value = value.deepCopy();
        return result;
    }
}

alias NodeState = ElementState!OwnedNode;
alias WayState = ElementState!OwnedWay;
alias RelationState = ElementState!OwnedRelation;

/** Overall relationship between base, local and remote state. */
enum ConflictDisposition : ubyte
{
    unchanged,
    localOnly,
    remoteOnly,
    identicalConcurrent,
    concurrentIndependent,
    bothDeleted,
    conflict,
    baselineMismatch,
}

/** Three-way relationship for one field/facet. */
enum FieldChange : ubyte
{
    unchanged,
    localOnly,
    remoteOnly,
    identicalConcurrent,
    independentConcurrent,
    conflict,
}

/** Exact per-key tag relationship. */
enum TagChange : ubyte
{
    unchanged,
    localOnly,
    remoteOnly,
    identicalConcurrent,
    conflict,
}

/**
 * One deterministic tag-key comparison.
 *
 * Counts expose duplicate-key cases explicitly. Values are populated only when
 * the corresponding side contains exactly one value for the key.
 */
struct TagConflict
{
    OwnedBytes key;
    TagChange change;

    size_t baseCount;
    size_t localCount;
    size_t remoteCount;

    OwnedBytes baseValue;
    OwnedBytes localValue;
    OwnedBytes remoteValue;

    @property bool duplicateKey() const @safe pure nothrow @nogc
    {
        return baseCount > 1 || localCount > 1 || remoteCount > 1;
    }
}

/** One conservative contiguous edit span relative to a base sequence. */
struct SequenceEditSpan
{
    bool changed;
    size_t baseStart;
    size_t baseLength;
    size_t replacementLength;

    @property size_t baseEnd() const @safe pure nothrow @nogc
    {
        return baseStart + baseLength;
    }
}

/** Relationship between ordered Way refs or Relation members. */
enum SequenceChange : ubyte
{
    unchanged,
    localOnly,
    remoteOnly,
    identicalConcurrent,
    independentConcurrent,
    overlappingOrComplex,
}

/**
 * Structured conflict facts sufficient for external presentation/resolution.
 *
 * No merged value is produced. requiresResolution is true for concurrent
 * independent changes as well as hard conflicts because osm-d deliberately
 * does not auto-merge even when changes appear non-overlapping.
 */
struct ConflictReport
{
    ElementType type;
    OsmId id;
    ConflictDisposition disposition = ConflictDisposition.unchanged;

    bool baseExists;
    bool localExists;
    bool remoteExists;

    bool baseHasVersion;
    int baseVersion;
    bool localHasVersion;
    int localVersion;
    bool remoteHasVersion;
    int remoteVersion;

    bool localChanged;
    bool remoteChanged;

    FieldChange existence = FieldChange.unchanged;
    FieldChange tags = FieldChange.unchanged;
    FieldChange location = FieldChange.unchanged;
    SequenceChange sequence = SequenceChange.unchanged;

    SequenceEditSpan localSequenceEdit;
    SequenceEditSpan remoteSequenceEdit;

    TagConflict[] tagChanges;
    bool hasDuplicateTagKeys;

    @property bool hasConflict() const @safe pure nothrow @nogc
    {
        return disposition == ConflictDisposition.conflict ||
               disposition == ConflictDisposition.baselineMismatch;
    }

    @property bool requiresResolution() const @safe pure nothrow @nogc
    {
        return hasConflict ||
               disposition == ConflictDisposition.concurrentIndependent;
    }

    /**
     * Whether authoritative remote state may replace local state without
     * discarding distinct local work.
     */
    @property bool remoteRefreshSafe() const @safe pure nothrow @nogc
    {
        return disposition == ConflictDisposition.unchanged ||
               disposition == ConflictDisposition.remoteOnly ||
               disposition == ConflictDisposition.identicalConcurrent ||
               disposition == ConflictDisposition.bothDeleted;
    }
}

/** Classify a Node base/local/remote triple. */
ConflictReport classifyConflict(
    scope ref const NodeState base,
    scope ref const NodeState local,
    scope ref const NodeState remote) @safe
{
    auto result = initializeReport!OwnedNode(base, local, remote);

    if (!classifyExistenceAndVersions(base, local, remote, result))
        return result;

    if (!base.exists || !local.exists || !remote.exists)
    {
        finishPresenceOnly(base, local, remote, result);
        return result;
    }

    result.tags = classifyTags(
        base.value.tags,
        local.value.tags,
        remote.value.tags,
        result.tagChanges,
        result.hasDuplicateTagKeys);

    const localLocationChanged =
        !sameNodeLocation(base.value, local.value);
    const remoteLocationChanged =
        !sameNodeLocation(base.value, remote.value);
    const localRemoteLocationSame =
        sameNodeLocation(local.value, remote.value);
    result.location = classifySimpleField(
        localLocationChanged,
        remoteLocationChanged,
        localRemoteLocationSame);

    finishPresent(
        base,
        local,
        remote,
        result,
        result.tags == FieldChange.conflict ||
        result.location == FieldChange.conflict);

    return result;
}

/** Classify a Way base/local/remote triple. */
ConflictReport classifyConflict(
    scope ref const WayState base,
    scope ref const WayState local,
    scope ref const WayState remote) @safe
{
    auto result = initializeReport!OwnedWay(base, local, remote);

    if (!classifyExistenceAndVersions(base, local, remote, result))
        return result;

    if (!base.exists || !local.exists || !remote.exists)
    {
        finishPresenceOnly(base, local, remote, result);
        return result;
    }

    result.tags = classifyTags(
        base.value.tags,
        local.value.tags,
        remote.value.tags,
        result.tagChanges,
        result.hasDuplicateTagKeys);

    result.sequence = classifySequence(
        base.value.nodes,
        local.value.nodes,
        remote.value.nodes,
        result.localSequenceEdit,
        result.remoteSequenceEdit);

    finishPresent(
        base,
        local,
        remote,
        result,
        result.tags == FieldChange.conflict ||
        result.sequence == SequenceChange.overlappingOrComplex);

    return result;
}

/** Classify a Relation base/local/remote triple. */
ConflictReport classifyConflict(
    scope ref const RelationState base,
    scope ref const RelationState local,
    scope ref const RelationState remote) @safe
{
    auto result = initializeReport!OwnedRelation(base, local, remote);

    if (!classifyExistenceAndVersions(base, local, remote, result))
        return result;

    if (!base.exists || !local.exists || !remote.exists)
    {
        finishPresenceOnly(base, local, remote, result);
        return result;
    }

    result.tags = classifyTags(
        base.value.tags,
        local.value.tags,
        remote.value.tags,
        result.tagChanges,
        result.hasDuplicateTagKeys);

    result.sequence = classifySequence(
        base.value.members,
        local.value.members,
        remote.value.members,
        result.localSequenceEdit,
        result.remoteSequenceEdit);

    finishPresent(
        base,
        local,
        remote,
        result,
        result.tags == FieldChange.conflict ||
        result.sequence == SequenceChange.overlappingOrComplex);

    return result;
}

private:

ConflictReport initializeReport(T)(
    scope ref const ElementState!T base,
    scope ref const ElementState!T local,
    scope ref const ElementState!T remote) @safe pure nothrow @nogc
{
    ConflictReport result;
    result.type = elementType!T;
    result.id = chooseId(base.id, local.id, remote.id);
    result.baseExists = base.exists;
    result.localExists = local.exists;
    result.remoteExists = remote.exists;
    result.baseHasVersion = base.hasVersion;
    result.baseVersion = base.version;
    result.localHasVersion = local.hasVersion;
    result.localVersion = local.version;
    result.remoteHasVersion = remote.hasVersion;
    result.remoteVersion = remote.version;
    return result;
}

bool classifyExistenceAndVersions(T)(
    scope ref const ElementState!T base,
    scope ref const ElementState!T local,
    scope ref const ElementState!T remote,
    ref ConflictReport result) @safe pure nothrow @nogc
{
    const id = result.id;
    if (id == 0 ||
        (base.id != 0 && base.id != id) ||
        (local.id != 0 && local.id != id) ||
        (remote.id != 0 && remote.id != id))
    {
        result.disposition = ConflictDisposition.baselineMismatch;
        return false;
    }

    if (base.exists)
    {
        if (!base.hasVersion || base.version <= 0)
        {
            result.disposition = ConflictDisposition.baselineMismatch;
            return false;
        }

        if (local.exists &&
            (!local.hasVersion || local.version != base.version))
        {
            result.disposition = ConflictDisposition.baselineMismatch;
            return false;
        }

        if (remote.exists)
        {
            if (!remote.hasVersion ||
                remote.version < base.version)
            {
                result.disposition = ConflictDisposition.baselineMismatch;
                return false;
            }

            if (remote.version == base.version &&
                !sameContent(base.value, remote.value))
            {
                result.disposition = ConflictDisposition.baselineMismatch;
                return false;
            }
        }
    }

    result.existence = classifyExistence(
        base.exists,
        local.exists,
        remote.exists);
    return true;
}

void finishPresenceOnly(T)(
    scope ref const ElementState!T base,
    scope ref const ElementState!T local,
    scope ref const ElementState!T remote,
    ref ConflictReport result) @safe pure nothrow @nogc
{
    if (!base.exists)
    {
        if (!local.exists && !remote.exists)
        {
            result.disposition = ConflictDisposition.unchanged;
            return;
        }
        if (local.exists && !remote.exists)
        {
            result.localChanged = true;
            result.disposition = ConflictDisposition.localOnly;
            return;
        }
        if (!local.exists && remote.exists)
        {
            result.remoteChanged = true;
            result.disposition = ConflictDisposition.remoteOnly;
            return;
        }

        result.localChanged = true;
        result.remoteChanged = true;
        result.disposition = sameContent(local.value, remote.value)
            ? ConflictDisposition.identicalConcurrent
            : ConflictDisposition.conflict;
        return;
    }

    if (!local.exists && !remote.exists)
    {
        result.localChanged = true;
        result.remoteChanged = true;
        result.disposition = ConflictDisposition.bothDeleted;
        return;
    }

    if (!local.exists)
    {
        result.localChanged = true;
        const remoteContentChanged =
            !sameContent(base.value, remote.value) ||
            newerRemoteVersion(base, remote);
        result.remoteChanged = remoteContentChanged;
        result.disposition = remoteContentChanged
            ? ConflictDisposition.conflict
            : ConflictDisposition.localOnly;
        return;
    }

    if (!remote.exists)
    {
        result.remoteChanged = true;
        const localContentChanged =
            !sameContent(base.value, local.value);
        result.localChanged = localContentChanged;
        result.disposition = localContentChanged
            ? ConflictDisposition.conflict
            : ConflictDisposition.remoteOnly;
        return;
    }
}

void finishPresent(T)(
    scope ref const ElementState!T base,
    scope ref const ElementState!T local,
    scope ref const ElementState!T remote,
    ref ConflictReport result,
    bool fieldConflict) @safe pure nothrow @nogc
{
    const localContentChanged = !sameContent(base.value, local.value);
    const remoteContentChanged = !sameContent(base.value, remote.value);
    const remoteVersionChanged = newerRemoteVersion(base, remote);

    result.localChanged = localContentChanged;
    result.remoteChanged = remoteContentChanged || remoteVersionChanged;

    if (!result.localChanged && !result.remoteChanged)
    {
        result.disposition = ConflictDisposition.unchanged;
        return;
    }

    if (result.localChanged && !result.remoteChanged)
    {
        result.disposition = ConflictDisposition.localOnly;
        return;
    }

    if (!result.localChanged && result.remoteChanged)
    {
        result.disposition = ConflictDisposition.remoteOnly;
        return;
    }

    if (sameContent(local.value, remote.value))
    {
        result.disposition = ConflictDisposition.identicalConcurrent;
        return;
    }

    if (fieldConflict)
    {
        result.disposition = ConflictDisposition.conflict;
        return;
    }

    result.disposition = ConflictDisposition.concurrentIndependent;
}

bool newerRemoteVersion(T)(
    scope ref const ElementState!T base,
    scope ref const ElementState!T remote)
    @safe pure nothrow @nogc
{
    return base.hasVersion &&
           remote.hasVersion &&
           remote.version > base.version;
}

FieldChange classifyExistence(
    bool baseExists,
    bool localExists,
    bool remoteExists) @safe pure nothrow @nogc
{
    const localChanged = localExists != baseExists;
    const remoteChanged = remoteExists != baseExists;

    if (!localChanged && !remoteChanged)
        return FieldChange.unchanged;
    if (localChanged && !remoteChanged)
        return FieldChange.localOnly;
    if (!localChanged && remoteChanged)
        return FieldChange.remoteOnly;
    if (localExists == remoteExists)
        return FieldChange.identicalConcurrent;
    return FieldChange.conflict;
}

FieldChange classifySimpleField(
    bool localChanged,
    bool remoteChanged,
    bool localRemoteSame) @safe pure nothrow @nogc
{
    if (!localChanged && !remoteChanged)
        return FieldChange.unchanged;
    if (localChanged && !remoteChanged)
        return FieldChange.localOnly;
    if (!localChanged && remoteChanged)
        return FieldChange.remoteOnly;
    if (localRemoteSame)
        return FieldChange.identicalConcurrent;
    return FieldChange.conflict;
}

FieldChange classifyTags(
    scope const(OwnedTag)[] base,
    scope const(OwnedTag)[] local,
    scope const(OwnedTag)[] remote,
    out TagConflict[] details,
    out bool duplicateKeys) @safe
{
    details = null;
    duplicateKeys = false;

    OwnedBytes[] keys;
    collectKeys(base, keys);
    collectKeys(local, keys);
    collectKeys(remote, keys);
    sortAndUniqueKeys(keys);

    bool anyLocal;
    bool anyRemote;
    bool anyConflict;
    bool allConcurrentIdentical = true;

    foreach (key; keys)
    {
        TagConflict entry;
        entry.key = key;
        entry.baseCount = countKey(base, key, entry.baseValue);
        entry.localCount = countKey(local, key, entry.localValue);
        entry.remoteCount = countKey(remote, key, entry.remoteValue);

        if (entry.duplicateKey)
            duplicateKeys = true;

        const localSameBase = sameKeyValues(base, local, key);
        const remoteSameBase = sameKeyValues(base, remote, key);
        const localSameRemote = sameKeyValues(local, remote, key);

        const localChanged = !localSameBase;
        const remoteChanged = !remoteSameBase;

        if (!localChanged && !remoteChanged)
            entry.change = TagChange.unchanged;
        else if (localChanged && !remoteChanged)
        {
            entry.change = TagChange.localOnly;
            anyLocal = true;
            allConcurrentIdentical = false;
        }
        else if (!localChanged && remoteChanged)
        {
            entry.change = TagChange.remoteOnly;
            anyRemote = true;
            allConcurrentIdentical = false;
        }
        else if (localSameRemote)
        {
            entry.change = TagChange.identicalConcurrent;
            anyLocal = true;
            anyRemote = true;
        }
        else
        {
            entry.change = TagChange.conflict;
            anyLocal = true;
            anyRemote = true;
            anyConflict = true;
            allConcurrentIdentical = false;
        }

        if (entry.change != TagChange.unchanged)
            details ~= entry;
    }

    if (anyConflict)
        return FieldChange.conflict;
    if (!anyLocal && !anyRemote)
        return FieldChange.unchanged;
    if (anyLocal && !anyRemote)
        return FieldChange.localOnly;
    if (!anyLocal && anyRemote)
        return FieldChange.remoteOnly;
    if (allConcurrentIdentical)
        return FieldChange.identicalConcurrent;
    return FieldChange.independentConcurrent;
}

SequenceChange classifySequence(T)(
    scope const(T)[] base,
    scope const(T)[] local,
    scope const(T)[] remote,
    out SequenceEditSpan localEdit,
    out SequenceEditSpan remoteEdit) @safe pure nothrow @nogc
{
    localEdit = editSpan(base, local);
    remoteEdit = editSpan(base, remote);

    if (!localEdit.changed && !remoteEdit.changed)
        return SequenceChange.unchanged;
    if (localEdit.changed && !remoteEdit.changed)
        return SequenceChange.localOnly;
    if (!localEdit.changed && remoteEdit.changed)
        return SequenceChange.remoteOnly;
    if (sameSequence(local, remote))
        return SequenceChange.identicalConcurrent;
    if (disjoint(localEdit, remoteEdit))
        return SequenceChange.independentConcurrent;
    return SequenceChange.overlappingOrComplex;
}

SequenceEditSpan editSpan(T)(
    scope const(T)[] base,
    scope const(T)[] changed) @safe pure nothrow @nogc
{
    SequenceEditSpan result;
    if (sameSequence(base, changed))
        return result;

    result.changed = true;

    size_t prefix;
    const commonLimit = base.length < changed.length
        ? base.length
        : changed.length;
    while (prefix < commonLimit &&
           sameItem(base[prefix], changed[prefix]))
        ++prefix;

    size_t suffix;
    while (suffix < base.length - prefix &&
           suffix < changed.length - prefix &&
           sameItem(
               base[base.length - 1 - suffix],
               changed[changed.length - 1 - suffix]))
        ++suffix;

    result.baseStart = prefix;
    result.baseLength = base.length - prefix - suffix;
    result.replacementLength = changed.length - prefix - suffix;
    return result;
}

bool disjoint(
    SequenceEditSpan a,
    SequenceEditSpan b) @safe pure nothrow @nogc
{
    if (!a.changed || !b.changed)
        return true;

    if (a.baseLength == 0 && b.baseLength == 0)
        return a.baseStart != b.baseStart;

    if (a.baseLength == 0)
        return a.baseStart < b.baseStart ||
               a.baseStart > b.baseEnd;

    if (b.baseLength == 0)
        return b.baseStart < a.baseStart ||
               b.baseStart > a.baseEnd;

    return a.baseEnd <= b.baseStart ||
           b.baseEnd <= a.baseStart;
}

bool sameContent(
    scope ref const OwnedNode a,
    scope ref const OwnedNode b) @safe pure nothrow @nogc
{
    return a.id == b.id &&
           sameNodeLocation(a, b) &&
           sameTagsExact(a.tags, b.tags);
}

bool sameContent(
    scope ref const OwnedWay a,
    scope ref const OwnedWay b) @safe pure nothrow @nogc
{
    return a.id == b.id &&
           sameTagsExact(a.tags, b.tags) &&
           sameSequence(a.nodes, b.nodes);
}

bool sameContent(
    scope ref const OwnedRelation a,
    scope ref const OwnedRelation b) @safe pure nothrow @nogc
{
    return a.id == b.id &&
           sameTagsExact(a.tags, b.tags) &&
           sameSequence(a.members, b.members);
}

bool sameNodeLocation(
    scope ref const OwnedNode a,
    scope ref const OwnedNode b) @safe pure nothrow @nogc
{
    return a.location.latitudeNanodegrees ==
               b.location.latitudeNanodegrees &&
           a.location.longitudeNanodegrees ==
               b.location.longitudeNanodegrees;
}

bool sameTagsExact(
    scope const(OwnedTag)[] a,
    scope const(OwnedTag)[] b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
        if (a[i].key != b[i].key ||
            a[i].value != b[i].value)
            return false;
    return true;
}

bool sameSequence(T)(
    scope const(T)[] a,
    scope const(T)[] b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
        if (!sameItem(a[i], b[i]))
            return false;
    return true;
}

bool sameItem(
    scope ref const OwnedNodeRef a,
    scope ref const OwnedNodeRef b) @safe pure nothrow @nogc
{
    if (a.id != b.id || a.hasLocation != b.hasLocation)
        return false;
    if (!a.hasLocation)
        return true;
    return a.location.latitudeNanodegrees ==
               b.location.latitudeNanodegrees &&
           a.location.longitudeNanodegrees ==
               b.location.longitudeNanodegrees;
}

bool sameItem(
    scope ref const OwnedRelationMember a,
    scope ref const OwnedRelationMember b) @safe pure nothrow @nogc
{
    return a.type == b.type &&
           a.id == b.id &&
           a.role == b.role;
}

void collectKeys(
    scope const(OwnedTag)[] tags,
    ref OwnedBytes[] keys) @safe
{
    foreach (ref const tag; tags)
        keys ~= tag.key;
}

void sortAndUniqueKeys(ref OwnedBytes[] keys) @safe
{
    foreach (i; 1 .. keys.length)
    {
        auto value = keys[i];
        size_t j = i;
        while (j > 0 && lessBytes(value, keys[j - 1]))
        {
            keys[j] = keys[j - 1];
            --j;
        }
        keys[j] = value;
    }

    if (keys.length < 2)
        return;

    size_t outIndex = 1;
    foreach (i; 1 .. keys.length)
    {
        if (keys[i] != keys[outIndex - 1])
            keys[outIndex++] = keys[i];
    }
    keys.length = outIndex;
}

bool lessBytes(
    scope const(ubyte)[] a,
    scope const(ubyte)[] b) @safe pure nothrow @nogc
{
    const count = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. count)
    {
        if (a[i] < b[i])
            return true;
        if (a[i] > b[i])
            return false;
    }
    return a.length < b.length;
}

size_t countKey(
    scope const(OwnedTag)[] tags,
    scope const(ubyte)[] key,
    out OwnedBytes singleValue) @safe pure nothrow @nogc
{
    singleValue = null;
    size_t count;
    foreach (ref const tag; tags)
    {
        if (tag.key != key)
            continue;
        ++count;
        if (count == 1)
            singleValue = tag.value;
        else
            singleValue = null;
    }
    return count;
}

bool sameKeyValues(
    scope const(OwnedTag)[] a,
    scope const(OwnedTag)[] b,
    scope const(ubyte)[] key) @safe pure nothrow @nogc
{
    size_t ia;
    size_t ib;

    for (;;)
    {
        while (ia < a.length && a[ia].key != key)
            ++ia;
        while (ib < b.length && b[ib].key != key)
            ++ib;

        const enda = ia == a.length;
        const endb = ib == b.length;
        if (enda || endb)
            return enda && endb;

        if (a[ia].value != b[ib].value)
            return false;

        ++ia;
        ++ib;
    }
}

OsmId chooseId(OsmId a, OsmId b, OsmId c)
    @safe pure nothrow @nogc
{
    if (a != 0) return a;
    if (b != 0) return b;
    return c;
}

private enum ElementType elementType(T) =
    is(T == OwnedNode) ? ElementType.node :
    is(T == OwnedWay) ? ElementType.way :
    ElementType.relation;

unittest
{
    import osm.model.owned : ownBytes;
    import osm.view.location : LocationView;

    OwnedNode baseNode;
    baseNode.id = 1;
    baseNode.metadata.hasVersion = true;
    baseNode.metadata.versionNumber = 7;
    baseNode.location = LocationView(10, 20);
    baseNode.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"Base"));

    auto localNode = baseNode.deepCopy();
    localNode.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"surface"),
        ownBytes(cast(const(ubyte)[])"paved"));

    auto remoteNode = baseNode.deepCopy();
    remoteNode.metadata.versionNumber = 8;
    remoteNode.location = LocationView(11, 20);

    auto base = NodeState.present(baseNode);
    auto local = NodeState.present(localNode);
    auto remote = NodeState.present(remoteNode);

    auto report = classifyConflict(base, local, remote);
    assert(report.disposition ==
        ConflictDisposition.concurrentIndependent);
    assert(report.tags == FieldChange.localOnly);
    assert(report.location == FieldChange.remoteOnly);
    assert(report.requiresResolution);
    assert(!report.hasConflict);
}

unittest
{
    OwnedWay baseWay;
    baseWay.id = 9;
    baseWay.metadata.hasVersion = true;
    baseWay.metadata.versionNumber = 3;
    OwnedNodeRef ref1;
    ref1.id = 1;
    OwnedNodeRef ref2;
    ref2.id = 2;
    OwnedNodeRef ref3;
    ref3.id = 3;
    baseWay.nodes = [ref1, ref2, ref3];

    auto localWay = baseWay.deepCopy();
    OwnedNodeRef localInsert;
    localInsert.id = 10;
    localWay.nodes = [ref1, localInsert, ref2, ref3];

    auto remoteWay = baseWay.deepCopy();
    remoteWay.metadata.versionNumber = 4;
    OwnedNodeRef remoteInsert;
    remoteInsert.id = 20;
    remoteWay.nodes = [ref1, ref2, ref3, remoteInsert];

    auto report = classifyConflict(
        WayState.present(baseWay),
        WayState.present(localWay),
        WayState.present(remoteWay));

    assert(report.sequence ==
        SequenceChange.independentConcurrent);
    assert(report.disposition ==
        ConflictDisposition.concurrentIndependent);
}

unittest
{
    import osm.model.owned : ownBytes;

    OwnedRelation baseRelation;
    baseRelation.id = 4;
    baseRelation.metadata.hasVersion = true;
    baseRelation.metadata.versionNumber = 2;
    baseRelation.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"type"),
        ownBytes(cast(const(ubyte)[])"route"));

    auto localRelation = baseRelation.deepCopy();
    localRelation.tags[0].value =
        ownBytes(cast(const(ubyte)[])"multipolygon");

    auto remoteRelation = baseRelation.deepCopy();
    remoteRelation.metadata.versionNumber = 3;
    remoteRelation.tags[0].value =
        ownBytes(cast(const(ubyte)[])"boundary");

    auto report = classifyConflict(
        RelationState.present(baseRelation),
        RelationState.present(localRelation),
        RelationState.present(remoteRelation));

    assert(report.hasConflict);
    assert(report.tags == FieldChange.conflict);
    assert(report.tagChanges.length == 1);
    assert(report.tagChanges[0].change == TagChange.conflict);
}
