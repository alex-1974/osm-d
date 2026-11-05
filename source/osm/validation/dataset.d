
/**
 * Dataset/reference validity for durable OSM semantic data.
 *
 * This layer sits between per-element representability and uploadability. It
 * checks typed OSM identities and references without applying upload metadata,
 * tag policy, coordinate, geometry, or editor-workflow rules.
 */
module osm.validation.dataset;

import osm.model.owned : OwnedDataset;
import osm.store.compact.store : OsmHandle, OsmStore;
import osm.view.element : ElementType, OsmId;

/** Reference-completeness contract for dataset validation. */
enum DatasetValidationMode : ubyte
{
    complete,
    partial,
}

/** First deterministic dataset/reference validity failure. */
enum DatasetValidationError : ubyte
{
    none,
    nullStore,
    zeroElementId,
    duplicateElementId,
    invalidReferenceType,
    zeroReference,
    missingReference,
    unresolvedLocalReference,
    deletedReference,
}

/** Location of the first dataset/reference validity failure. */
struct DatasetValidationIssue
{
    DatasetValidationError error = DatasetValidationError.none;

    ElementType elementType;
    OsmId elementId;
    size_t elementIndex;
    bool hasElement;

    size_t childIndex;
    bool hasChild;

    ElementType referenceType;
    OsmId referenceId;
    bool hasReference;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == DatasetValidationError.none;
    }
}

/**
 * Validate identities and typed references in one OwnedDataset.
 *
 * Complete mode requires every typed reference to resolve inside the dataset.
 * Partial mode permits an unresolved positive/server reference because OSM
 * extracts and API responses may intentionally omit the target. Missing
 * negative/local references are invalid in both modes.
 *
 * Relation cycles and self-reference are representable graph structure, not a
 * failure at this layer. Recursive traversal is a separate topology concern.
 */
bool validateDataset(
    ref const OwnedDataset dataset,
    DatasetValidationMode mode,
    out DatasetValidationIssue issue)
    @safe
{
    issue = DatasetValidationIssue.init;

    bool[OsmId] nodeIds;
    bool[OsmId] wayIds;
    bool[OsmId] relationIds;

    foreach (i, ref const node; dataset.nodes)
    {
        if (!addIdentity(
                ElementType.node,
                node.id,
                i,
                nodeIds,
                issue))
            return false;
    }

    foreach (i, ref const way; dataset.ways)
    {
        if (!addIdentity(
                ElementType.way,
                way.id,
                i,
                wayIds,
                issue))
            return false;
    }

    foreach (i, ref const relation; dataset.relations)
    {
        if (!addIdentity(
                ElementType.relation,
                relation.id,
                i,
                relationIds,
                issue))
            return false;
    }

    foreach (i, ref const way; dataset.ways)
    {
        setElement(issue, ElementType.way, way.id, i);

        foreach (childIndex, ref const nodeRef; way.nodes)
        {
            if (!validateOwnedReference(
                    ElementType.node,
                    nodeRef.id,
                    childIndex,
                    mode,
                    nodeIds,
                    wayIds,
                    relationIds,
                    issue))
                return false;
        }
    }

    foreach (i, ref const relation; dataset.relations)
    {
        setElement(issue, ElementType.relation, relation.id, i);

        foreach (childIndex, ref const member; relation.members)
        {
            if (!validateOwnedReference(
                    member.type,
                    member.id,
                    childIndex,
                    mode,
                    nodeIds,
                    wayIds,
                    relationIds,
                    issue))
                return false;
        }
    }

    issue = DatasetValidationIssue.init;
    return true;
}

/**
 * Validate live identities and references in one OsmStore.
 *
 * Retained tombstones are distinguished from ordinary omitted positive
 * objects. A live element referencing a target explicitly deleted in the same
 * editable store is deletedReference even in partial mode.
 */
bool validateDataset(
    OsmStore store,
    DatasetValidationMode mode,
    out DatasetValidationIssue issue)
    @safe
{
    issue = DatasetValidationIssue.init;

    if (store is null)
    {
        issue.error = DatasetValidationError.nullStore;
        return false;
    }

    bool[OsmId] deletedNodes;
    bool[OsmId] deletedWays;
    bool[OsmId] deletedRelations;

    const counts = store.counts;
    if (counts.nodeSlots != counts.liveNodes)
        store.collectDeletedIdentities(ElementType.node, deletedNodes);
    if (counts.waySlots != counts.liveWays)
        store.collectDeletedIdentities(ElementType.way, deletedWays);
    if (counts.relationSlots != counts.liveRelations)
        store.collectDeletedIdentities(
            ElementType.relation,
            deletedRelations);

    size_t elementIndex;
    auto ways = store.ways;
    while (!ways.empty)
    {
        auto way = ways.front;
        setElement(issue, ElementType.way, way.id, elementIndex);

        size_t childIndex;
        auto nodes = way.nodes;
        while (!nodes.empty)
        {
            auto nodeRef = nodes.front;
            if (!validateStoreReference(
                    store,
                    ElementType.node,
                    nodeRef.id,
                    childIndex,
                    mode,
                    deletedNodes,
                    deletedWays,
                    deletedRelations,
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
        setElement(
            issue,
            ElementType.relation,
            relation.id,
            elementIndex);

        size_t childIndex;
        auto members = relation.members;
        while (!members.empty)
        {
            auto member = members.front;
            if (!validateStoreReference(
                    store,
                    member.type,
                    member.id,
                    childIndex,
                    mode,
                    deletedNodes,
                    deletedWays,
                    deletedRelations,
                    issue))
                return false;

            members.popFront();
            ++childIndex;
        }

        relations.popFront();
        ++elementIndex;
    }

    issue = DatasetValidationIssue.init;
    return true;
}

private:

bool addIdentity(
    ElementType type,
    OsmId id,
    size_t index,
    ref bool[OsmId] ids,
    ref DatasetValidationIssue issue)
    @safe
{
    setElement(issue, type, id, index);

    if (id == 0)
        return fail(issue, DatasetValidationError.zeroElementId);

    if (id in ids)
        return fail(issue, DatasetValidationError.duplicateElementId);

    ids[id] = true;
    return true;
}

void setElement(
    ref DatasetValidationIssue issue,
    ElementType type,
    OsmId id,
    size_t index)
    @safe pure nothrow @nogc
{
    issue = DatasetValidationIssue.init;
    issue.elementType = type;
    issue.elementId = id;
    issue.elementIndex = index;
    issue.hasElement = true;
}

bool fail(
    ref DatasetValidationIssue issue,
    DatasetValidationError error)
    @safe pure nothrow @nogc
{
    issue.error = error;
    return false;
}

bool failReference(
    ref DatasetValidationIssue issue,
    DatasetValidationError error,
    size_t childIndex,
    ElementType type,
    OsmId id)
    @safe pure nothrow @nogc
{
    issue.error = error;
    issue.childIndex = childIndex;
    issue.hasChild = true;
    issue.referenceType = type;
    issue.referenceId = id;
    issue.hasReference = true;
    return false;
}

bool validReferenceType(ElementType type)
    @safe pure nothrow @nogc
{
    return type == ElementType.node ||
           type == ElementType.way ||
           type == ElementType.relation;
}

bool containsOwnedIdentity(
    ElementType type,
    OsmId id,
    ref bool[OsmId] nodeIds,
    ref bool[OsmId] wayIds,
    ref bool[OsmId] relationIds)
    @safe
{
    if (type == ElementType.node)
        return (id in nodeIds) !is null;
    if (type == ElementType.way)
        return (id in wayIds) !is null;
    if (type == ElementType.relation)
        return (id in relationIds) !is null;
    return false;
}

bool validateOwnedReference(
    ElementType type,
    OsmId id,
    size_t childIndex,
    DatasetValidationMode mode,
    ref bool[OsmId] nodeIds,
    ref bool[OsmId] wayIds,
    ref bool[OsmId] relationIds,
    ref DatasetValidationIssue issue)
    @safe
{
    if (!validReferenceType(type))
    {
        return failReference(
            issue,
            DatasetValidationError.invalidReferenceType,
            childIndex,
            type,
            id);
    }

    if (id == 0)
    {
        return failReference(
            issue,
            DatasetValidationError.zeroReference,
            childIndex,
            type,
            id);
    }

    if (containsOwnedIdentity(
            type,
            id,
            nodeIds,
            wayIds,
            relationIds))
        return true;

    if (id < 0)
    {
        return failReference(
            issue,
            DatasetValidationError.unresolvedLocalReference,
            childIndex,
            type,
            id);
    }

    if (mode == DatasetValidationMode.complete)
    {
        return failReference(
            issue,
            DatasetValidationError.missingReference,
            childIndex,
            type,
            id);
    }

    return true;
}

bool validateStoreReference(
    OsmStore store,
    ElementType type,
    OsmId id,
    size_t childIndex,
    DatasetValidationMode mode,
    ref bool[OsmId] deletedNodes,
    ref bool[OsmId] deletedWays,
    ref bool[OsmId] deletedRelations,
    ref DatasetValidationIssue issue)
    @safe
{
    if (!validReferenceType(type))
    {
        return failReference(
            issue,
            DatasetValidationError.invalidReferenceType,
            childIndex,
            type,
            id);
    }

    if (id == 0)
    {
        return failReference(
            issue,
            DatasetValidationError.zeroReference,
            childIndex,
            type,
            id);
    }

    OsmHandle handle;
    if (store.find(type, id, handle))
        return true;

    const deleted =
        type == ElementType.node ? (id in deletedNodes) !is null :
        type == ElementType.way ? (id in deletedWays) !is null :
        (id in deletedRelations) !is null;

    if (deleted)
    {
        return failReference(
            issue,
            DatasetValidationError.deletedReference,
            childIndex,
            type,
            id);
    }

    if (id < 0)
    {
        return failReference(
            issue,
            DatasetValidationError.unresolvedLocalReference,
            childIndex,
            type,
            id);
    }

    if (mode == DatasetValidationMode.complete)
    {
        return failReference(
            issue,
            DatasetValidationError.missingReference,
            childIndex,
            type,
            id);
    }

    return true;
}

unittest
{
    import osm.model.owned :
        OwnedNode,
        OwnedNodeRef,
        OwnedRelation,
        OwnedRelationMember,
        OwnedWay;

    OwnedDataset data;

    OwnedNode node;
    node.id = 1;
    data.nodes ~= node;

    OwnedWay way;
    way.id = 2;
    way.nodes ~= OwnedNodeRef(1);
    data.ways ~= way;

    OwnedRelation relation;
    relation.id = 3;
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        2,
        null);
    relation.members ~= OwnedRelationMember(
        ElementType.relation,
        3,
        null);
    data.relations ~= relation;

    DatasetValidationIssue issue;
    assert(validateDataset(
        data,
        DatasetValidationMode.complete,
        issue));
    assert(issue.ok);
}

unittest
{
    import osm.model.owned : OwnedNodeRef, OwnedWay;

    OwnedDataset data;
    OwnedWay way;
    way.id = 1;
    way.nodes ~= OwnedNodeRef(999);
    data.ways ~= way;

    DatasetValidationIssue issue;
    assert(validateDataset(
        data,
        DatasetValidationMode.partial,
        issue));

    assert(!validateDataset(
        data,
        DatasetValidationMode.complete,
        issue));
    assert(issue.error == DatasetValidationError.missingReference);
    assert(issue.elementType == ElementType.way);
    assert(issue.elementId == 1);
    assert(issue.childIndex == 0);
    assert(issue.referenceType == ElementType.node);
    assert(issue.referenceId == 999);
}

unittest
{
    import osm.model.owned : OwnedNodeRef, OwnedWay;

    OwnedDataset data;
    OwnedWay way;
    way.id = -2;
    way.nodes ~= OwnedNodeRef(-1);
    data.ways ~= way;

    DatasetValidationIssue issue;
    assert(!validateDataset(
        data,
        DatasetValidationMode.partial,
        issue));
    assert(issue.error ==
        DatasetValidationError.unresolvedLocalReference);
    assert(issue.referenceId == -1);
}

unittest
{
    import osm.model.owned : OwnedNode, OwnedWay;

    OwnedDataset data;

    OwnedNode node;
    node.id = 7;
    data.nodes ~= node;
    data.nodes ~= node;

    OwnedWay way;
    way.id = 7;
    data.ways ~= way;

    DatasetValidationIssue issue;
    assert(!validateDataset(
        data,
        DatasetValidationMode.partial,
        issue));
    assert(issue.error == DatasetValidationError.duplicateElementId);
    assert(issue.elementType == ElementType.node);
    assert(issue.elementIndex == 1);

    data.nodes.length = 1;
    data.nodes[0].id = 0;
    assert(!validateDataset(
        data,
        DatasetValidationMode.partial,
        issue));
    assert(issue.error == DatasetValidationError.zeroElementId);
}

unittest
{
    import osm.model.owned :
        OwnedRelation,
        OwnedRelationMember;

    OwnedDataset data;

    OwnedRelation a;
    a.id = 10;
    a.members ~= OwnedRelationMember(
        ElementType.relation,
        11,
        null);

    OwnedRelation b;
    b.id = 11;
    b.members ~= OwnedRelationMember(
        ElementType.relation,
        10,
        null);

    data.relations ~= a;
    data.relations ~= b;

    DatasetValidationIssue issue;
    assert(validateDataset(
        data,
        DatasetValidationMode.complete,
        issue));

    data.relations[0].members[0].type = cast(ElementType)99;
    assert(!validateDataset(
        data,
        DatasetValidationMode.complete,
        issue));
    assert(issue.error ==
        DatasetValidationError.invalidReferenceType);
    assert(issue.elementType == ElementType.relation);
    assert(issue.elementId == 10);
    assert(issue.childIndex == 0);
}

unittest
{
    import osm.model.owned :
        OwnedNode,
        OwnedNodeRef,
        OwnedWay;
    import osm.store.compact.store : StoreStatus;

    auto store = new OsmStore();
    StoreStatus status;

    OwnedNode node;
    node.id = 1;
    OsmHandle nodeHandle;
    assert(store.add(node, nodeHandle, status));

    OwnedWay way;
    way.id = 2;
    way.nodes ~= OwnedNodeRef(1);
    OsmHandle wayHandle;
    assert(store.add(way, wayHandle, status));

    DatasetValidationIssue issue;
    assert(validateDataset(
        store,
        DatasetValidationMode.complete,
        issue));

    assert(store.remove(nodeHandle, status));

    assert(!validateDataset(
        store,
        DatasetValidationMode.partial,
        issue));
    assert(issue.error == DatasetValidationError.deletedReference);
    assert(issue.elementType == ElementType.way);
    assert(issue.referenceType == ElementType.node);
    assert(issue.referenceId == 1);
}
