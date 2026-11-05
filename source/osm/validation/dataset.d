/**
 * Dataset-level OSM reference validation.
 *
 * This layer sits after per-element/format validity and before operation-
 * specific policy such as uploadability. It answers whether typed Way/Relation
 * references are coherent for a dataset that the caller declares complete or
 * deliberately partial.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-05
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.validation.dataset;

import osm.model.owned :
    OwnedDataset,
    OwnedNode,
    OwnedNodeRef,
    OwnedRelationMember,
    OwnedWay;
import osm.store.compact.store :
    OsmHandle,
    OsmStore,
    StoreStatus;
import osm.view.element :
    ElementType,
    OsmId;

/**
 * Reference-completeness policy for one dataset validation.
 *
 * complete is deliberately .init and fail-closed: every typed reference must
 * resolve to a live element in the dataset/store.
 *
 * partial permits only an absent positive/server reference, representing an
 * object that may legitimately lie outside an extract or API response. Missing
 * local/negative references, zero references and references to known store
 * tombstones remain errors.
 */
enum DatasetReferenceMode : ubyte
{
    complete,
    partial,
}

/** First deterministic dataset/reference validation failure. */
enum DatasetReferenceError : ubyte
{
    none,
    invalidMode,
    invalidDataset,
    invalidElementId,
    duplicateElementId,
    invalidReferenceType,
    zeroReference,
    unresolvedLocalReference,
    missingReference,
    deletedReference,
}

/**
 * Diagnostic for the first invalid dataset identity or reference.
 *
 * elementIndex is the zero-based position inside the corresponding
 * Node/Way/Relation sequence. For OsmStore it is the live iteration position,
 * not an internal slot number.
 *
 * childIndex identifies a Way node reference or Relation member when
 * hasChild is true. referenceType/referenceId identify the target when
 * hasReference is true.
 */
struct DatasetReferenceIssue
{
    DatasetReferenceError error = DatasetReferenceError.none;

    size_t elementIndex;
    ElementType elementType;
    OsmId elementId;
    bool hasElement;

    size_t childIndex;
    bool hasChild;

    ElementType referenceType;
    OsmId referenceId;
    bool hasReference;

    /** Return true when no validation error is present. */
    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == DatasetReferenceError.none;
    }
}

/**
 * Counts produced while validating dataset references.
 *
 * On success these counts cover the complete live dataset. On failure they
 * contain the deterministic prefix processed up to and including the failing
 * reference. elements is the total source element count known before reference
 * traversal.
 */
struct DatasetReferenceSummary
{
    size_t elements;
    size_t references;
    size_t resolvedReferences;
    size_t unresolvedReferences;
    size_t invalidReferences;

    /**
     * Whether every examined reference resolved to a live target.
     *
     * A successful partial validation may therefore return false here while
     * the function itself returns true.
     */
    @property bool referentiallyComplete() const
        @safe pure nothrow @nogc
    {
        return unresolvedReferences == 0 &&
               invalidReferences == 0;
    }
}

/**
 * Validate typed references in an owned semantic dataset.
 *
 * Before reference traversal, this overload builds a temporary typed identity
 * index and rejects zero/duplicate element IDs. The index is proportional to
 * the number of elements because OwnedDataset intentionally carries no
 * persistent lookup structure.
 *
 * Way node-reference order/duplicates and Relation member order/duplicates are
 * preserved and legal. Relation self-reference and cycles are also legal at
 * this validation stage when every target exists; recursive traversal is
 * responsible for cycle protection.
 *
 * Returns:
 *   true when the dataset satisfies mode. In partial mode, true may include
 *   absent positive references; they are counted in
 *   summary.unresolvedReferences.
 */
bool validateDatasetReferences(
    scope ref const OwnedDataset dataset,
    DatasetReferenceMode mode,
    out DatasetReferenceSummary summary,
    out DatasetReferenceIssue issue)
    @safe
{
    summary = DatasetReferenceSummary.init;
    issue = DatasetReferenceIssue.init;

    if (!validMode(mode))
        return failMode(summary, issue);

    summary.elements =
        dataset.nodes.length +
        dataset.ways.length +
        dataset.relations.length;

    OwnedIdentityLookup lookup;
    if (!indexOwnedIdentities(dataset, lookup, issue))
        return false;

    foreach (elementIndex, ref const way; dataset.ways)
    {
        foreach (childIndex, ref const nodeRef; way.nodes)
        {
            if (!validateReference(
                    lookup,
                    mode,
                    ElementType.way,
                    way.id,
                    elementIndex,
                    childIndex,
                    ElementType.node,
                    nodeRef.id,
                    summary,
                    issue))
                return false;
        }
    }

    foreach (elementIndex, ref const relation; dataset.relations)
    {
        foreach (childIndex, ref const member; relation.members)
        {
            if (!validElementType(member.type))
            {
                ++summary.references;
                ++summary.invalidReferences;
                setReferenceIssue(
                    issue,
                    DatasetReferenceError.invalidReferenceType,
                    ElementType.relation,
                    relation.id,
                    elementIndex,
                    childIndex,
                    member.type,
                    member.id);
                return false;
            }

            if (!validateReference(
                    lookup,
                    mode,
                    ElementType.relation,
                    relation.id,
                    elementIndex,
                    childIndex,
                    member.type,
                    member.id,
                    summary,
                    issue))
                return false;
        }
    }

    issue = DatasetReferenceIssue.init;
    return true;
}

/**
 * Validate typed references in the live view of an editable OsmStore.
 *
 * Live target lookup reuses the store's primary typed indexes. Store tombstones
 * are collected into a temporary typed identity set so a known locally deleted
 * target is never reclassified as a legitimate partial-extract absence.
 * Allocation is therefore proportional to the number of tombstones, not to the
 * number of live elements or references.
 *
 * Deleted Ways/Relations are not source elements because normal store iteration
 * describes the current live dataset. Incoming references from live parents
 * remain visible and fail with DatasetReferenceError.deletedReference.
 */
bool validateDatasetReferences(
    OsmStore store,
    DatasetReferenceMode mode,
    out DatasetReferenceSummary summary,
    out DatasetReferenceIssue issue)
    @safe
{
    summary = DatasetReferenceSummary.init;
    issue = DatasetReferenceIssue.init;

    if (!validMode(mode))
        return failMode(summary, issue);

    if (store is null)
    {
        issue.error = DatasetReferenceError.invalidDataset;
        return false;
    }

    const counts = store.counts;
    summary.elements = counts.liveTotal;

    StoreIdentityLookup lookup;
    lookup.store = store;

    DeletedIdentityCollector collector;
    collector.identities = &lookup.deleted;
    store.visitDeletedIdentities(collector);

    size_t elementIndex;
    auto ways = store.ways;
    while (!ways.empty)
    {
        auto way = ways.front;
        auto nodes = way.nodes;
        size_t childIndex;

        while (!nodes.empty)
        {
            const nodeRef = nodes.front;
            if (!validateReference(
                    lookup,
                    mode,
                    ElementType.way,
                    way.id,
                    elementIndex,
                    childIndex,
                    ElementType.node,
                    nodeRef.id,
                    summary,
                    issue))
                return false;

            nodes.popFront();
            ++childIndex;
        }

        ways.popFront();
        ++elementIndex;
    }

    elementIndex = 0;
    auto relations = store.relations;
    while (!relations.empty)
    {
        auto relation = relations.front;
        auto members = relation.members;
        size_t childIndex;

        while (!members.empty)
        {
            const member = members.front;
            if (!validElementType(member.type))
            {
                ++summary.references;
                ++summary.invalidReferences;
                setReferenceIssue(
                    issue,
                    DatasetReferenceError.invalidReferenceType,
                    ElementType.relation,
                    relation.id,
                    elementIndex,
                    childIndex,
                    member.type,
                    member.id);
                return false;
            }

            if (!validateReference(
                    lookup,
                    mode,
                    ElementType.relation,
                    relation.id,
                    elementIndex,
                    childIndex,
                    member.type,
                    member.id,
                    summary,
                    issue))
                return false;

            members.popFront();
            ++childIndex;
        }

        relations.popFront();
        ++elementIndex;
    }

    issue = DatasetReferenceIssue.init;
    return true;
}

private:

struct Identity
{
    ElementType type;
    OsmId id;
}

struct OwnedIdentityLookup
{
    bool[Identity] live;

    bool contains(ElementType type, OsmId id) @safe
    {
        return (Identity(type, id) in live) !is null;
    }

    bool deletedTarget(ElementType, OsmId) const
        @safe pure nothrow @nogc
    {
        return false;
    }
}

struct StoreIdentityLookup
{
    OsmStore store;
    bool[Identity] deleted;

    bool contains(ElementType type, OsmId id) @safe nothrow @nogc
    {
        OsmHandle ignored;
        return store.find(type, id, ignored);
    }

    bool deletedTarget(ElementType type, OsmId id) @safe
    {
        return (Identity(type, id) in deleted) !is null;
    }
}

struct DeletedIdentityCollector
{
    bool[Identity]* identities;

    void put(ElementType type, OsmId id) @safe
    {
        (*identities)[Identity(type, id)] = true;
    }
}

bool indexOwnedIdentities(
    scope ref const OwnedDataset dataset,
    ref OwnedIdentityLookup lookup,
    ref DatasetReferenceIssue issue)
    @safe
{
    foreach (elementIndex, ref const node; dataset.nodes)
    {
        if (!indexIdentity(
                lookup,
                ElementType.node,
                node.id,
                elementIndex,
                issue))
            return false;
    }

    foreach (elementIndex, ref const way; dataset.ways)
    {
        if (!indexIdentity(
                lookup,
                ElementType.way,
                way.id,
                elementIndex,
                issue))
            return false;
    }

    foreach (elementIndex, ref const relation; dataset.relations)
    {
        if (!indexIdentity(
                lookup,
                ElementType.relation,
                relation.id,
                elementIndex,
                issue))
            return false;
    }

    return true;
}

bool indexIdentity(
    ref OwnedIdentityLookup lookup,
    ElementType type,
    OsmId id,
    size_t elementIndex,
    ref DatasetReferenceIssue issue)
    @safe
{
    if (id == 0)
    {
        setElementIssue(
            issue,
            DatasetReferenceError.invalidElementId,
            type,
            id,
            elementIndex);
        return false;
    }

    const identity = Identity(type, id);
    if ((identity in lookup.live) !is null)
    {
        setElementIssue(
            issue,
            DatasetReferenceError.duplicateElementId,
            type,
            id,
            elementIndex);
        return false;
    }

    lookup.live[identity] = true;
    return true;
}

bool validateReference(Lookup)(
    ref Lookup lookup,
    DatasetReferenceMode mode,
    ElementType elementType,
    OsmId elementId,
    size_t elementIndex,
    size_t childIndex,
    ElementType referenceType,
    OsmId referenceId,
    ref DatasetReferenceSummary summary,
    ref DatasetReferenceIssue issue)
    @safe
{
    ++summary.references;

    if (referenceId == 0)
    {
        ++summary.invalidReferences;
        setReferenceIssue(
            issue,
            DatasetReferenceError.zeroReference,
            elementType,
            elementId,
            elementIndex,
            childIndex,
            referenceType,
            referenceId);
        return false;
    }

    if (lookup.contains(referenceType, referenceId))
    {
        ++summary.resolvedReferences;
        return true;
    }

    if (lookup.deletedTarget(referenceType, referenceId))
    {
        ++summary.invalidReferences;
        setReferenceIssue(
            issue,
            DatasetReferenceError.deletedReference,
            elementType,
            elementId,
            elementIndex,
            childIndex,
            referenceType,
            referenceId);
        return false;
    }

    if (referenceId < 0)
    {
        ++summary.invalidReferences;
        setReferenceIssue(
            issue,
            DatasetReferenceError.unresolvedLocalReference,
            elementType,
            elementId,
            elementIndex,
            childIndex,
            referenceType,
            referenceId);
        return false;
    }

    if (mode == DatasetReferenceMode.complete)
    {
        ++summary.invalidReferences;
        setReferenceIssue(
            issue,
            DatasetReferenceError.missingReference,
            elementType,
            elementId,
            elementIndex,
            childIndex,
            referenceType,
            referenceId);
        return false;
    }

    ++summary.unresolvedReferences;
    return true;
}

bool validMode(DatasetReferenceMode mode) @safe pure nothrow @nogc
{
    return mode == DatasetReferenceMode.complete ||
           mode == DatasetReferenceMode.partial;
}

bool validElementType(ElementType type) @safe pure nothrow @nogc
{
    return cast(ubyte)type <= cast(ubyte)ElementType.relation;
}

bool failMode(
    ref DatasetReferenceSummary summary,
    ref DatasetReferenceIssue issue)
    @safe pure nothrow @nogc
{
    summary = DatasetReferenceSummary.init;
    issue = DatasetReferenceIssue.init;
    issue.error = DatasetReferenceError.invalidMode;
    return false;
}

void setElementIssue(
    ref DatasetReferenceIssue issue,
    DatasetReferenceError error,
    ElementType type,
    OsmId id,
    size_t elementIndex)
    @safe pure nothrow @nogc
{
    issue = DatasetReferenceIssue.init;
    issue.error = error;
    issue.elementIndex = elementIndex;
    issue.elementType = type;
    issue.elementId = id;
    issue.hasElement = true;
}

void setReferenceIssue(
    ref DatasetReferenceIssue issue,
    DatasetReferenceError error,
    ElementType elementType,
    OsmId elementId,
    size_t elementIndex,
    size_t childIndex,
    ElementType referenceType,
    OsmId referenceId)
    @safe pure nothrow @nogc
{
    setElementIssue(
        issue,
        error,
        elementType,
        elementId,
        elementIndex);
    issue.childIndex = childIndex;
    issue.hasChild = true;
    issue.referenceType = referenceType;
    issue.referenceId = referenceId;
    issue.hasReference = true;
}

unittest
{
    static assert(DatasetReferenceMode.init == DatasetReferenceMode.complete);

    OwnedDataset data;

    data.nodes ~= typeof(data.nodes[0])(1);
    data.nodes ~= typeof(data.nodes[0])(2);

    typeof(data.ways[0]) way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(1);
    way.nodes ~= OwnedNodeRef(1);
    way.nodes ~= OwnedNodeRef(2);
    data.ways ~= way;

    typeof(data.relations[0]) relation;
    relation.id = 20;
    relation.members ~= OwnedRelationMember(ElementType.way, 10);
    relation.members ~= OwnedRelationMember(ElementType.relation, 20);
    relation.members ~= OwnedRelationMember(ElementType.way, 10);
    data.relations ~= relation;

    DatasetReferenceSummary summary;
    DatasetReferenceIssue issue;
    assert(validateDatasetReferences(
        data,
        DatasetReferenceMode.complete,
        summary,
        issue));
    assert(issue.ok);
    assert(summary.elements == 4);
    assert(summary.references == 6);
    assert(summary.resolvedReferences == 6);
    assert(summary.unresolvedReferences == 0);
    assert(summary.invalidReferences == 0);
    assert(summary.referentiallyComplete);
}

unittest
{
    OwnedDataset data;

    typeof(data.ways[0]) way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(99);
    data.ways ~= way;

    DatasetReferenceSummary summary;
    DatasetReferenceIssue issue;

    assert(!validateDatasetReferences(
        data,
        DatasetReferenceMode.complete,
        summary,
        issue));
    assert(issue.error == DatasetReferenceError.missingReference);
    assert(issue.elementType == ElementType.way);
    assert(issue.elementId == 10);
    assert(issue.elementIndex == 0);
    assert(issue.childIndex == 0);
    assert(issue.referenceType == ElementType.node);
    assert(issue.referenceId == 99);
    assert(summary.invalidReferences == 1);

    assert(validateDatasetReferences(
        data,
        DatasetReferenceMode.partial,
        summary,
        issue));
    assert(issue.ok);
    assert(summary.unresolvedReferences == 1);
    assert(!summary.referentiallyComplete);
}

unittest
{
    OwnedDataset data;
    typeof(data.ways[0]) way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(-1);
    data.ways ~= way;

    DatasetReferenceSummary summary;
    DatasetReferenceIssue issue;
    assert(!validateDatasetReferences(
        data,
        DatasetReferenceMode.partial,
        summary,
        issue));
    assert(issue.error == DatasetReferenceError.unresolvedLocalReference);
    assert(issue.referenceId == -1);

    data.ways[0].nodes[0].id = 0;
    assert(!validateDatasetReferences(
        data,
        DatasetReferenceMode.partial,
        summary,
        issue));
    assert(issue.error == DatasetReferenceError.zeroReference);
}

unittest
{
    OwnedDataset data;
    data.nodes ~= typeof(data.nodes[0])(1);
    data.nodes ~= typeof(data.nodes[0])(1);

    DatasetReferenceSummary summary;
    DatasetReferenceIssue issue;
    assert(!validateDatasetReferences(
        data,
        DatasetReferenceMode.complete,
        summary,
        issue));
    assert(issue.error == DatasetReferenceError.duplicateElementId);
    assert(issue.elementType == ElementType.node);
    assert(issue.elementIndex == 1);
}

unittest
{
    OwnedDataset data;
    typeof(data.relations[0]) relation;
    relation.id = 20;
    relation.members ~=
        OwnedRelationMember(cast(ElementType)255, 1);
    data.relations ~= relation;

    DatasetReferenceSummary summary;
    DatasetReferenceIssue issue;
    assert(!validateDatasetReferences(
        data,
        DatasetReferenceMode.partial,
        summary,
        issue));
    assert(issue.error == DatasetReferenceError.invalidReferenceType);
    assert(issue.childIndex == 0);
}
