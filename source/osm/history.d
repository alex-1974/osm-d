/**
 * Ordered authoritative OSM element histories.
 *
 * Historical versions are deliberately distinct from live OwnedNode/Way/
 * Relation values. In particular, current OSM API history may represent a
 * deleted Node with visible=false and without lat/lon; the history model keeps
 * that absence explicit instead of inventing a (0,0) location.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-08
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.history;

import osm.model.owned :
    OwnedMetadata,
    OwnedNode,
    OwnedNodeRef,
    OwnedRelation,
    OwnedRelationMember,
    OwnedTag,
    OwnedWay;
import osm.view.element : OsmId;
import osm.view.location : LocationView;

/** Whether a history intentionally covers every version from 1 to its tail. */
enum HistoryCoverage : ubyte
{
    partial,
    complete,
}

/** Visibility state encoded by one historical version. */
enum HistoricalVisibility : ubyte
{
    unknown,
    visible,
    deleted,
}

/** Structured history-construction failure. */
enum HistoryError : ubyte
{
    none,
    invalidIdentity,
    missingVersion,
    invalidVersion,
    mixedIdentity,
    nonIncreasingVersion,
    incompleteSequence,
    missingNodeLocation,
}

/** Diagnostic for a rejected history sequence. */
struct HistoryStatus
{
    HistoryError error = HistoryError.none;
    OsmId id;
    int versionNumber;
    size_t index;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == HistoryError.none;
    }
}

/** One authoritative historical Node version. */
struct HistoricalNodeVersion
{
    OsmId id;
    OwnedMetadata metadata;

    /**
     * Historical Nodes may omit location when deleted.
     *
     * location is meaningful only when hasLocation is true.
     */
    bool hasLocation;
    LocationView location;

    /** Exact tags supplied for this historical version, if any. */
    OwnedTag[] tags;

    @property HistoricalVisibility visibility() const
        @safe pure nothrow @nogc
    {
        return visibilityOf(metadata);
    }

    @property bool deleted() const @safe pure nothrow @nogc
    {
        return visibility == HistoricalVisibility.deleted;
    }

    /** Create a fully located historical version from an ordinary owned Node. */
    static HistoricalNodeVersion fromOwned(
        scope ref const OwnedNode source) @safe
    {
        HistoricalNodeVersion result;
        result.id = source.id;
        result.metadata = source.metadata;
        result.hasLocation = true;
        result.location = LocationView(
            source.location.latitudeNanodegrees,
            source.location.longitudeNanodegrees);
        result.tags = source.tags.dup;
        return result;
    }

    /**
     * Convert this historical version to a live semantic Node when possible.
     *
     * Deleted versions and versions without a location deliberately fail.
     */
    bool toOwned(out OwnedNode result) const @safe
    {
        result = OwnedNode.init;
        if (deleted || !hasLocation)
            return false;

        result.id = id;
        result.metadata = metadata;
        result.location = LocationView(
            location.latitudeNanodegrees,
            location.longitudeNanodegrees);
        result.tags = tags.dup;
        return true;
    }

    HistoricalNodeVersion deepCopy() const @safe
    {
        HistoricalNodeVersion result;
        result.id = id;
        result.metadata = metadata;
        result.hasLocation = hasLocation;
        if (hasLocation)
        {
            result.location = LocationView(
                location.latitudeNanodegrees,
                location.longitudeNanodegrees);
        }
        result.tags = tags.dup;
        return result;
    }
}

/** One authoritative historical Way version. */
struct HistoricalWayVersion
{
    OsmId id;
    OwnedMetadata metadata;
    OwnedTag[] tags;
    OwnedNodeRef[] nodes;

    @property HistoricalVisibility visibility() const
        @safe pure nothrow @nogc
    {
        return visibilityOf(metadata);
    }

    @property bool deleted() const @safe pure nothrow @nogc
    {
        return visibility == HistoricalVisibility.deleted;
    }

    static HistoricalWayVersion fromOwned(
        scope ref const OwnedWay source) @safe
    {
        HistoricalWayVersion result;
        result.id = source.id;
        result.metadata = source.metadata;
        result.tags = source.tags.dup;
        result.nodes = source.nodes.dup;
        return result;
    }

    /** Convert a non-deleted historical version to an ordinary owned Way. */
    bool toOwned(out OwnedWay result) const @safe
    {
        result = OwnedWay.init;
        if (deleted)
            return false;

        result.id = id;
        result.metadata = metadata;
        result.tags = tags.dup;
        result.nodes = nodes.dup;
        return true;
    }

    HistoricalWayVersion deepCopy() const @safe
    {
        HistoricalWayVersion result;
        result.id = id;
        result.metadata = metadata;
        result.tags = tags.dup;
        result.nodes = nodes.dup;
        return result;
    }
}

/** One authoritative historical Relation version. */
struct HistoricalRelationVersion
{
    OsmId id;
    OwnedMetadata metadata;
    OwnedTag[] tags;
    OwnedRelationMember[] members;

    @property HistoricalVisibility visibility() const
        @safe pure nothrow @nogc
    {
        return visibilityOf(metadata);
    }

    @property bool deleted() const @safe pure nothrow @nogc
    {
        return visibility == HistoricalVisibility.deleted;
    }

    static HistoricalRelationVersion fromOwned(
        scope ref const OwnedRelation source) @safe
    {
        HistoricalRelationVersion result;
        result.id = source.id;
        result.metadata = source.metadata;
        result.tags = source.tags.dup;
        result.members = source.members.dup;
        return result;
    }

    /**
     * Convert a non-deleted historical version to an ordinary owned Relation.
     */
    bool toOwned(out OwnedRelation result) const @safe
    {
        result = OwnedRelation.init;
        if (deleted)
            return false;

        result.id = id;
        result.metadata = metadata;
        result.tags = tags.dup;
        result.members = members.dup;
        return true;
    }

    HistoricalRelationVersion deepCopy() const @safe
    {
        HistoricalRelationVersion result;
        result.id = id;
        result.metadata = metadata;
        result.tags = tags.dup;
        result.members = members.dup;
        return result;
    }
}

/**
 * Owning ordered version sequence for one OSM element identity.
 *
 * T is one Historical*Version type. Entries are ordered by strictly increasing
 * OSM version number. Partial histories may contain gaps; complete histories
 * must start at version 1 and be contiguous.
 */
struct ElementHistory(T)
if (isHistoricalVersion!T)
{
private:
    T[] versions_;
    HistoryCoverage coverage_;

public:
    /**
     * Validate and own an ordered history sequence.
     *
     * No sorting or repair is performed. On failure result is empty and no
     * partially validated history escapes.
     */
    static bool create(
        scope const(T)[] versions,
        HistoryCoverage coverage,
        out ElementHistory result,
        out HistoryStatus status) @safe
    {
        result = ElementHistory.init;
        status = HistoryStatus.init;

        if (versions.length == 0)
        {
            result.coverage_ = coverage;
            return true;
        }

        const firstId = versions[0].id;
        status.id = firstId;
        if (firstId <= 0)
        {
            status.error = HistoryError.invalidIdentity;
            return false;
        }

        int previous;
        T[] owned;
        owned.length = versions.length;

        foreach (i, ref const value; versions)
        {
            status.index = i;
            status.id = value.id;

            if (value.id != firstId)
            {
                status.error = HistoryError.mixedIdentity;
                return false;
            }

            if (!value.metadata.hasVersion)
            {
                status.error = HistoryError.missingVersion;
                return false;
            }

            const versionNumber = value.metadata.versionNumber;
            status.versionNumber = versionNumber;
            if (versionNumber <= 0)
            {
                status.error = HistoryError.invalidVersion;
                return false;
            }

            if (i != 0 && versionNumber <= previous)
            {
                status.error = HistoryError.nonIncreasingVersion;
                return false;
            }

            if (coverage == HistoryCoverage.complete &&
                versionNumber != cast(int)i + 1)
            {
                status.error = HistoryError.incompleteSequence;
                return false;
            }

            static if (is(T == HistoricalNodeVersion))
            {
                if (value.visibility != HistoricalVisibility.deleted &&
                    !value.hasLocation)
                {
                    status.error = HistoryError.missingNodeLocation;
                    return false;
                }
            }

            owned[i] = value.deepCopy();
            previous = versionNumber;
        }

        result.versions_ = owned;
        result.coverage_ = coverage;
        status = HistoryStatus.init;
        status.id = firstId;
        return true;
    }

    /// Number of retained versions.
    @property size_t length() const @safe pure nothrow @nogc
    {
        return versions_.length;
    }

    /// True when no version is retained.
    @property bool empty() const @safe pure nothrow @nogc
    {
        return versions_.length == 0;
    }

    /// Declared coverage contract.
    @property HistoryCoverage coverage() const @safe pure nothrow @nogc
    {
        return coverage_;
    }

    /// Element identity, or zero for an empty history.
    @property OsmId id() const @safe pure nothrow @nogc
    {
        return versions_.length == 0 ? 0 : versions_[0].id;
    }

    /// First retained version number, or zero for an empty history.
    @property int firstVersion() const @safe pure nothrow @nogc
    {
        return versions_.length == 0
            ? 0
            : versions_[0].metadata.versionNumber;
    }

    /// Last retained version number, or zero for an empty history.
    @property int lastVersion() const @safe pure nothrow @nogc
    {
        return versions_.length == 0
            ? 0
            : versions_[$ - 1].metadata.versionNumber;
    }

    /** Whether at least one version number is absent between retained entries. */
    @property bool hasGap() const @safe pure nothrow @nogc
    {
        if (versions_.length < 2)
            return false;

        foreach (i; 1 .. versions_.length)
        {
            if (versions_[i].metadata.versionNumber !=
                versions_[i - 1].metadata.versionNumber + 1)
                return true;
        }
        return firstVersion != 1;
    }

    /**
     * Borrow all retained versions in server/version order.
     *
     * The returned const slice remains valid while this history is not
     * reassigned or destroyed.
     */
    @property const(T)[] versions() const return
        @safe pure nothrow @nogc
    {
        return versions_;
    }

    /**
     * Lookup one exact version without allocation.
     *
     * Returns a zero- or one-element const slice. This avoids a raw pointer and
     * prevents mutation of history-owned child arrays.
     */
    const(T)[] findVersion(int number) const return
        @safe pure nothrow @nogc
    {
        size_t low;
        size_t high = versions_.length;

        while (low < high)
        {
            const middle = low + (high - low) / 2;
            const current = versions_[middle].metadata.versionNumber;

            if (current < number)
                low = middle + 1;
            else
                high = middle;
        }

        if (low < versions_.length &&
            versions_[low].metadata.versionNumber == number)
            return versions_[low .. low + 1];

        return null;
    }

    /// Visibility/deletion state of one retained version.
    HistoricalVisibility visibility(int number) const
        @safe pure nothrow @nogc
    {
        const found = findVersion(number);
        return found.length == 0
            ? HistoricalVisibility.unknown
            : found[0].visibility;
    }

    /** Create an independently mutable copy of this history. */
    ElementHistory deepCopy() const @safe
    {
        ElementHistory result;
        result.coverage_ = coverage_;
        result.versions_.length = versions_.length;
        foreach (i, ref const value; versions_)
            result.versions_[i] = value.deepCopy();
        return result;
    }
}

/// Typed consumer aliases.
alias NodeHistory = ElementHistory!HistoricalNodeVersion;
alias WayHistory = ElementHistory!HistoricalWayVersion;
alias RelationHistory = ElementHistory!HistoricalRelationVersion;

private:

enum bool isHistoricalVersion(T) =
    is(T == HistoricalNodeVersion) ||
    is(T == HistoricalWayVersion) ||
    is(T == HistoricalRelationVersion);

HistoricalVisibility visibilityOf(scope ref const OwnedMetadata metadata)
    @safe pure nothrow @nogc
{
    if (!metadata.hasVisibility)
        return HistoricalVisibility.unknown;
    return metadata.visible
        ? HistoricalVisibility.visible
        : HistoricalVisibility.deleted;
}

unittest
{
    OwnedNode live;
    live.id = 42;
    live.metadata.hasVersion = true;
    live.metadata.versionNumber = 1;
    live.metadata.hasVisibility = true;
    live.metadata.visible = true;
    live.location = LocationView(10, 20);

    auto v1 = HistoricalNodeVersion.fromOwned(live);

    HistoricalNodeVersion v2;
    v2.id = 42;
    v2.metadata = live.metadata;
    v2.metadata.versionNumber = 2;
    v2.metadata.visible = false;
    assert(!v2.hasLocation);

    NodeHistory history;
    HistoryStatus status;
    assert(NodeHistory.create(
        [v1, v2],
        HistoryCoverage.complete,
        history,
        status));
    assert(status.ok);
    assert(history.length == 2);
    assert(history.firstVersion == 1);
    assert(history.lastVersion == 2);
    assert(!history.hasGap);
    assert(history.findVersion(2).length == 1);
    assert(history.visibility(2) == HistoricalVisibility.deleted);

    OwnedNode impossibleLive;
    assert(!history.findVersion(2)[0].toOwned(impossibleLive));
}

unittest
{
    OwnedWay owned;
    owned.id = 7;
    owned.metadata.hasVersion = true;
    owned.metadata.versionNumber = 2;

    auto v2 = HistoricalWayVersion.fromOwned(owned);
    auto v4 = v2.deepCopy();
    v4.metadata.versionNumber = 4;

    WayHistory history;
    HistoryStatus status;
    assert(WayHistory.create(
        [v2, v4],
        HistoryCoverage.partial,
        history,
        status));
    assert(history.hasGap);

    assert(!WayHistory.create(
        [v2, v4],
        HistoryCoverage.complete,
        history,
        status));
    assert(status.error == HistoryError.incompleteSequence);
}
