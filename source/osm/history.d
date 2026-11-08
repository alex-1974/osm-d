/**
 * Ordered OSM element version histories.
 *
 * History here means authoritative OSM server history, not editor undo/redo.
 * Each history owns independent mutable child arrays while immutable byte
 * strings may be shared with the source values.
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
    OwnedRelation,
    OwnedWay;
import osm.view.element :
    ElementType,
    OsmId;

/** Whether a history intentionally covers every version from 1 to its tail. */
enum HistoryCoverage : ubyte
{
    partial,
    complete,
}

/** Visibility state of one historical version. */
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
}

/** Diagnostic for a rejected history sequence. */
struct HistoryStatus
{
    HistoryError error = HistoryError.none;
    ElementType type;
    OsmId id;
    int version;
    size_t index;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == HistoryError.none;
    }
}

/**
 * Owning ordered version sequence for one OSM element.
 *
 * T must be OwnedNode, OwnedWay or OwnedRelation. Entries are ordered by
 * strictly increasing OSM version number. Partial histories may contain gaps;
 * complete histories must start at version 1 and be contiguous.
 *
 * The sequence is separate from OsmStore because a store represents current
 * editable state while this type represents durable historical versions.
 */
struct ElementHistory(T)
if (is(T == OwnedNode) || is(T == OwnedWay) || is(T == OwnedRelation))
{
private:
    T[] versions_;
    HistoryCoverage coverage_;

public:
    /**
     * Validate and own an ordered history sequence.
     *
     * On failure result is empty and no partially validated history escapes.
     */
    static bool create(
        scope const(T)[] versions,
        HistoryCoverage coverage,
        out ElementHistory result,
        out HistoryStatus status) @safe
    {
        result = ElementHistory.init;
        status = HistoryStatus.init;
        status.type = elementType!T;

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

            const version = value.metadata.versionNumber;
            status.version = version;
            if (version <= 0)
            {
                status.error = HistoryError.invalidVersion;
                return false;
            }

            if (i != 0 && version <= previous)
            {
                status.error = HistoryError.nonIncreasingVersion;
                return false;
            }

            if (coverage == HistoryCoverage.complete &&
                version != cast(int)i + 1)
            {
                status.error = HistoryError.incompleteSequence;
                return false;
            }

            owned[i] = value.deepCopy();
            previous = version;
        }

        result.versions_ = owned;
        result.coverage_ = coverage;
        status = HistoryStatus.init;
        status.type = elementType!T;
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

    /**
     * Whether at least one version number is absent between retained entries.
     *
     * A partial history may legitimately have gaps. A complete history never
     * does because create rejects that representation.
     */
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
        return false;
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
     * Returns a zero- or one-element const slice. This avoids exposing a raw
     * pointer and prevents mutation of history-owned child arrays.
     */
    const(T)[] version(int number) const return
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

    /// Visibility/deletion state encoded by one retained version's metadata.
    HistoricalVisibility visibility(int number) const
        @safe pure nothrow @nogc
    {
        const found = version(number);
        if (found.length == 0)
            return HistoricalVisibility.unknown;

        const metadata = found[0].metadata;
        if (!metadata.hasVisibility)
            return HistoricalVisibility.unknown;

        return metadata.visible
            ? HistoricalVisibility.visible
            : HistoricalVisibility.deleted;
    }

    /**
     * Create an independently mutable copy of this history.
     *
     * Immutable byte strings remain safely shared.
     */
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
alias NodeHistory = ElementHistory!OwnedNode;
alias WayHistory = ElementHistory!OwnedWay;
alias RelationHistory = ElementHistory!OwnedRelation;

private enum ElementType elementType(T) =
    is(T == OwnedNode) ? ElementType.node :
    is(T == OwnedWay) ? ElementType.way :
    ElementType.relation;

unittest
{
    OwnedNode v1;
    v1.id = 42;
    v1.metadata.hasVersion = true;
    v1.metadata.versionNumber = 1;
    v1.metadata.hasVisibility = true;
    v1.metadata.visible = true;

    auto v2 = v1.deepCopy();
    v2.metadata.versionNumber = 2;
    v2.metadata.visible = false;

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
    assert(history.version(2).length == 1);
    assert(history.visibility(2) == HistoricalVisibility.deleted);
}

unittest
{
    OwnedWay v2;
    v2.id = 7;
    v2.metadata.hasVersion = true;
    v2.metadata.versionNumber = 2;

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
