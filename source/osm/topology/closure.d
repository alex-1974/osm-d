/**
 * Bounded cycle-safe OSM topology closure traversal.
 *
 * Child closure walks Relation membership depth-first in source order and also
 * expands resolved Way members to their ordered Node references. Duplicate
 * edges are emitted. Relations are expanded at most once to break cycles.
 *
 * Parent closure emits distinct parent elements in deterministic first-
 * discovery order and uses existing reverse indexes.
 */
module osm.topology.closure;

import osm.model.owned :
    OwnedDataset,
    OwnedRelation,
    OwnedWay;
import osm.store :
    OsmHandle,
    OsmStore,
    StoreRelationView,
    StoreStatus,
    StoreWayView;
import osm.topology.resolution :
    OwnedDatasetIndex,
    ReferenceResolutionState,
    resolveMembers,
    resolveNodes;
import osm.view.element : ElementType, OsmId;

/** Why a bounded topology traversal stopped with an error. */
enum TopologyTraversalError : ubyte
{
    none,
    invalidLimits,
    invalidRoot,
    staleIndex,
    visitLimit,
    relationLimit,
    depthLimit,
    invalidatedStore,
}

/** Explicit work bounds for hostile or unexpectedly deep OSM graphs. */
struct TopologyTraversalLimits
{
    size_t maxDepth = 64;
    size_t maxVisits = 1_000_000;
    size_t maxRelations = 100_000;

    @property bool valid() const @safe pure nothrow @nogc
    {
        return maxDepth > 0 &&
               maxVisits > 0 &&
               maxRelations > 0;
    }
}

/** Result and progress of one closure traversal. */
struct TopologyTraversalStatus
{
    TopologyTraversalError error = TopologyTraversalError.none;
    bool completed;
    int control;

    size_t visits;
    size_t relationsExpanded;
    size_t maxDepthReached;

    ElementType type;
    OsmId id;
    bool hasObject;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == TopologyTraversalError.none;
    }
}

private struct StoreRelationQueueEntry
{
    OsmHandle handle;
    OsmId id;
    size_t depth;
}

private struct OwnedRelationQueueEntry
{
    size_t index;
    OsmId id;
    size_t depth;
}

/**
 * Reusable visited sets and queues for closure traversal.
 *
 * One workspace must not be shared concurrently. reset removes prior keys
 * while retaining ordinary dynamic-array/AA capacity where the runtime can.
 */
struct TopologyTraversalWorkspace
{
private:
    bool[OsmId] _relations;
    OsmId[] _relationKeys;

    bool[OsmId] _ways;
    OsmId[] _wayKeys;

    StoreRelationQueueEntry[] _storeRelations;
    OwnedRelationQueueEntry[] _ownedRelations;

public:
    void reset() @safe
    {
        foreach (id; _relationKeys)
            _relations.remove(id);
        _relationKeys.length = 0;

        foreach (id; _wayKeys)
            _ways.remove(id);
        _wayKeys.length = 0;

        _storeRelations.length = 0;
        _ownedRelations.length = 0;
    }

package(osm.topology):
    bool markRelation(OsmId id) @safe
    {
        if (id in _relations)
            return false;
        _relations[id] = true;
        _relationKeys ~= id;
        return true;
    }

    bool relationSeen(OsmId id) @safe nothrow
    {
        return (id in _relations) !is null;
    }

    bool markWay(OsmId id) @safe
    {
        if (id in _ways)
            return false;
        _ways[id] = true;
        _wayKeys ~= id;
        return true;
    }
}

/** One descendant edge discovered through an OsmStore Relation closure. */
struct StoreChildVisit
{
    ElementType parentType;
    OsmId parentId;
    size_t childIndex;

    ElementType type;
    OsmId id;
    size_t depth;

    ReferenceResolutionState resolution;
    OsmHandle target;

    bool relationPreviouslyExpanded;
}

/** One descendant edge discovered through an OwnedDataset Relation closure. */
struct OwnedChildVisit
{
    ElementType parentType;
    OsmId parentId;
    size_t childIndex;

    ElementType type;
    OsmId id;
    size_t depth;

    ReferenceResolutionState resolution;
    size_t targetIndex;

    bool relationPreviouslyExpanded;
}

/** One distinct parent discovered through OsmStore reverse indexes. */
struct StoreParentVisit
{
    ElementType type;
    OsmId id;
    size_t depth;
    OsmHandle target;
}

/** One distinct parent discovered through an OwnedDataset explicit index. */
struct OwnedParentVisit
{
    ElementType type;
    OsmId id;
    size_t depth;
    size_t targetIndex;
}

/**
 * Walk the full descendant closure of one live Store Relation.
 *
 * Every Relation-member occurrence is emitted. A resolved Way member is then
 * expanded to its ordered Node-reference occurrences. Resolved Relations are
 * recursively expanded once; later duplicate/cyclic Relation occurrences are
 * emitted with relationPreviouslyExpanded true.
 *
 * Unresolved references are emitted through ReferenceResolutionState and do
 * not by themselves fail traversal. Use validateDataset when complete or
 * partial dataset integrity must be enforced before traversal.
 *
 * A non-zero visitor return is an intentional early stop: the function returns
 * true, status remains non-error, and status.completed is false.
 *
 * Structural store mutation from the visitor is not permitted.
 */
bool walkRelationClosure(
    OsmStore store,
    OsmHandle root,
    ref TopologyTraversalWorkspace workspace,
    TopologyTraversalLimits limits,
    scope int delegate(scope ref const StoreChildVisit) @safe visitor,
    out TopologyTraversalStatus status)
    @safe
{
    status = TopologyTraversalStatus.init;
    workspace.reset();

    if (!limits.valid || store is null)
    {
        status.error = store is null
            ? TopologyTraversalError.invalidRoot
            : TopologyTraversalError.invalidLimits;
        return false;
    }

    StoreRelationView relation;
    StoreStatus storeStatus;
    if (!store.relation(root, relation, storeStatus))
    {
        status.error = TopologyTraversalError.invalidRoot;
        return false;
    }

    status.type = ElementType.relation;
    status.id = relation.id;
    status.hasObject = true;

    workspace.markRelation(relation.id);
    status.relationsExpanded = 1;

    if (!walkStoreRelationChildren(
            store,
            relation,
            1,
            workspace,
            limits,
            visitor,
            status))
        return false;

    if (status.control != 0)
        return true;

    status.completed = true;
    return true;
}

/** Walk the full descendant closure of one indexed OwnedDataset Relation. */
bool walkRelationClosure(
    ref const OwnedDataset dataset,
    ref OwnedDatasetIndex index,
    OsmId rootRelationId,
    ref TopologyTraversalWorkspace workspace,
    TopologyTraversalLimits limits,
    scope int delegate(scope ref const OwnedChildVisit) @safe visitor,
    out TopologyTraversalStatus status)
    @safe
{
    status = TopologyTraversalStatus.init;
    workspace.reset();

    if (!limits.valid)
    {
        status.error = TopologyTraversalError.invalidLimits;
        return false;
    }

    size_t relationIndex;
    if (!index.find(
            ElementType.relation,
            rootRelationId,
            relationIndex) ||
        relationIndex >= dataset.relations.length ||
        dataset.relations[relationIndex].id != rootRelationId)
    {
        status.error = TopologyTraversalError.invalidRoot;
        status.type = ElementType.relation;
        status.id = rootRelationId;
        status.hasObject = true;
        return false;
    }

    status.type = ElementType.relation;
    status.id = rootRelationId;
    status.hasObject = true;

    workspace.markRelation(rootRelationId);
    status.relationsExpanded = 1;

    if (!walkOwnedRelationChildren(
            dataset,
            index,
            relationIndex,
            1,
            workspace,
            limits,
            visitor,
            status))
        return false;

    if (status.control != 0)
        return true;

    status.completed = true;
    return true;
}

/**
 * Walk distinct live Store parents of one typed OSM identity.
 *
 * The root itself need not be loaded. This is intentional for partial extracts:
 * reverse indexes can expose parents of an unresolved positive child.
 */
bool walkParentClosure(
    OsmStore store,
    ElementType rootType,
    OsmId rootId,
    ref TopologyTraversalWorkspace workspace,
    TopologyTraversalLimits limits,
    scope int delegate(scope ref const StoreParentVisit) @safe visitor,
    out TopologyTraversalStatus status)
    @safe
{
    status = TopologyTraversalStatus.init;
    workspace.reset();

    if (store is null ||
        !validElementType(rootType) ||
        rootId == 0)
    {
        status.error = TopologyTraversalError.invalidRoot;
        status.type = rootType;
        status.id = rootId;
        status.hasObject = true;
        return false;
    }

    if (!limits.valid)
    {
        status.error = TopologyTraversalError.invalidLimits;
        return false;
    }

    status.type = rootType;
    status.id = rootId;
    status.hasObject = true;

    if (rootType == ElementType.relation)
        workspace.markRelation(rootId);

    if (rootType == ElementType.node)
    {
        auto ways = store.parentWays(rootId);
        while (!ways.empty)
        {
            auto way = ways.front;
            ways.popFront();

            if (!workspace.markWay(way.id))
                continue;

            if (!emitStoreParent(
                    way.handle,
                    ElementType.way,
                    way.id,
                    1,
                    limits,
                    visitor,
                    status))
                return status.control != 0;

            if (status.control != 0)
                return true;
        }
    }

    auto directRelations = store.parentRelations(rootType, rootId);
    while (!directRelations.empty)
    {
        auto relation = directRelations.front;
        directRelations.popFront();

        if (!enqueueStoreRelationParent(
                relation,
                1,
                workspace,
                limits,
                visitor,
                status))
            return status.control != 0;

        if (status.control != 0)
            return true;
    }

    if (rootType == ElementType.node)
    {
        auto ways = store.parentWays(rootId);
        while (!ways.empty)
        {
            auto way = ways.front;
            ways.popFront();

            auto parents =
                store.parentRelations(ElementType.way, way.id);
            while (!parents.empty)
            {
                auto relation = parents.front;
                parents.popFront();

                if (!enqueueStoreRelationParent(
                        relation,
                        2,
                        workspace,
                        limits,
                        visitor,
                        status))
                    return status.control != 0;

                if (status.control != 0)
                    return true;
            }
        }
    }

    size_t queuePosition;
    while (queuePosition < workspace._storeRelations.length)
    {
        auto current = workspace._storeRelations[queuePosition++];

        auto parents = store.parentRelations(
            ElementType.relation,
            current.id);
        while (!parents.empty)
        {
            auto relation = parents.front;
            parents.popFront();

            if (!enqueueStoreRelationParent(
                    relation,
                    current.depth + 1,
                    workspace,
                    limits,
                    visitor,
                    status))
                return status.control != 0;

            if (status.control != 0)
                return true;
        }
    }

    status.completed = true;
    return true;
}

/** Walk distinct parents using an explicit OwnedDatasetIndex reverse index. */
bool walkParentClosure(
    ref const OwnedDataset dataset,
    ref OwnedDatasetIndex index,
    ElementType rootType,
    OsmId rootId,
    ref TopologyTraversalWorkspace workspace,
    TopologyTraversalLimits limits,
    scope int delegate(scope ref const OwnedParentVisit) @safe visitor,
    out TopologyTraversalStatus status)
    @safe
{
    status = TopologyTraversalStatus.init;
    workspace.reset();

    if (!validElementType(rootType) || rootId == 0)
    {
        status.error = TopologyTraversalError.invalidRoot;
        status.type = rootType;
        status.id = rootId;
        status.hasObject = true;
        return false;
    }

    if (!limits.valid)
    {
        status.error = TopologyTraversalError.invalidLimits;
        return false;
    }

    status.type = rootType;
    status.id = rootId;
    status.hasObject = true;

    if (rootType == ElementType.relation)
        workspace.markRelation(rootId);

    if (rootType == ElementType.node)
    {
        foreach (wayIndex; index.parentWays(rootId))
        {
            if (wayIndex >= dataset.ways.length)
            {
                status.error = TopologyTraversalError.staleIndex;
                return false;
            }

            ref const way = dataset.ways[wayIndex];
            if (!workspace.markWay(way.id))
                continue;

            if (!emitOwnedParent(
                    ElementType.way,
                    way.id,
                    wayIndex,
                    1,
                    limits,
                    visitor,
                    status))
                return status.control != 0;

            if (status.control != 0)
                return true;
        }
    }

    foreach (relationIndex;
             index.parentRelations(rootType, rootId))
    {
        if (!enqueueOwnedRelationParent(
                dataset,
                relationIndex,
                1,
                workspace,
                limits,
                visitor,
                status))
            return status.control != 0;

        if (status.control != 0)
            return true;
    }

    if (rootType == ElementType.node)
    {
        foreach (wayIndex; index.parentWays(rootId))
        {
            if (wayIndex >= dataset.ways.length)
            {
                status.error = TopologyTraversalError.staleIndex;
                return false;
            }

            const wayId = dataset.ways[wayIndex].id;
            foreach (relationIndex;
                     index.parentRelations(
                         ElementType.way,
                         wayId))
            {
                if (!enqueueOwnedRelationParent(
                        dataset,
                        relationIndex,
                        2,
                        workspace,
                        limits,
                        visitor,
                        status))
                    return status.control != 0;

                if (status.control != 0)
                    return true;
            }
        }
    }

    size_t queuePosition;
    while (queuePosition < workspace._ownedRelations.length)
    {
        auto current = workspace._ownedRelations[queuePosition++];

        foreach (relationIndex;
                 index.parentRelations(
                     ElementType.relation,
                     current.id))
        {
            if (!enqueueOwnedRelationParent(
                    dataset,
                    relationIndex,
                    current.depth + 1,
                    workspace,
                    limits,
                    visitor,
                    status))
                return status.control != 0;

            if (status.control != 0)
                return true;
        }
    }

    status.completed = true;
    return true;
}

private:

bool walkStoreRelationChildren(
    OsmStore store,
    StoreRelationView relation,
    size_t depth,
    ref TopologyTraversalWorkspace workspace,
    TopologyTraversalLimits limits,
    scope int delegate(scope ref const StoreChildVisit) @safe visitor,
    ref TopologyTraversalStatus status)
    @safe
{
    auto members = store.resolveMembers(relation);
    size_t childIndex;

    while (!members.empty)
    {
        auto resolved = members.front;
        members.popFront();

        if (!reserveVisit(
                resolved.member.type,
                resolved.member.id,
                depth,
                limits,
                status))
            return false;

        StoreChildVisit visit;
        visit.parentType = ElementType.relation;
        visit.parentId = relation.id;
        visit.childIndex = childIndex;
        visit.type = resolved.member.type;
        visit.id = resolved.member.id;
        visit.depth = depth;
        visit.resolution = resolved.state;
        visit.target = resolved.target;
        visit.relationPreviouslyExpanded =
            visit.type == ElementType.relation &&
            resolved.resolved &&
            workspace.relationSeen(visit.id);

        ++status.visits;
        updateDepth(depth, status);

        status.control = visitor(visit);
        if (status.control != 0)
            return true;

        if (resolved.resolved)
        {
            if (visit.type == ElementType.way)
            {
                StoreWayView way;
                StoreStatus storeStatus;
                if (!store.way(resolved.target, way, storeStatus))
                {
                    status.error =
                        TopologyTraversalError.invalidatedStore;
                    return false;
                }

                if (!walkStoreWayNodes(
                        store,
                        way,
                        depth + 1,
                        limits,
                        visitor,
                        status))
                    return false;

                if (status.control != 0)
                    return true;
            }
            else if (visit.type == ElementType.relation &&
                     !visit.relationPreviouslyExpanded)
            {
                if (depth >= limits.maxDepth)
                {
                    status.error = TopologyTraversalError.depthLimit;
                    status.type = visit.type;
                    status.id = visit.id;
                    status.hasObject = true;
                    return false;
                }

                if (status.relationsExpanded >=
                    limits.maxRelations)
                {
                    status.error =
                        TopologyTraversalError.relationLimit;
                    status.type = visit.type;
                    status.id = visit.id;
                    status.hasObject = true;
                    return false;
                }

                StoreRelationView child;
                StoreStatus storeStatus;
                if (!store.relation(
                        resolved.target,
                        child,
                        storeStatus))
                {
                    status.error =
                        TopologyTraversalError.invalidatedStore;
                    return false;
                }

                workspace.markRelation(visit.id);
                ++status.relationsExpanded;

                if (!walkStoreRelationChildren(
                        store,
                        child,
                        depth + 1,
                        workspace,
                        limits,
                        visitor,
                        status))
                    return false;

                if (status.control != 0)
                    return true;
            }
        }

        ++childIndex;
    }

    return true;
}

bool walkStoreWayNodes(
    OsmStore store,
    StoreWayView way,
    size_t depth,
    TopologyTraversalLimits limits,
    scope int delegate(scope ref const StoreChildVisit) @safe visitor,
    ref TopologyTraversalStatus status)
    @safe
{
    if (depth > limits.maxDepth)
    {
        status.error = TopologyTraversalError.depthLimit;
        status.type = ElementType.way;
        status.id = way.id;
        status.hasObject = true;
        return false;
    }

    auto nodes = store.resolveNodes(way);
    size_t childIndex;

    while (!nodes.empty)
    {
        auto resolved = nodes.front;
        nodes.popFront();

        if (!reserveVisit(
                ElementType.node,
                resolved.reference.id,
                depth,
                limits,
                status))
            return false;

        StoreChildVisit visit;
        visit.parentType = ElementType.way;
        visit.parentId = way.id;
        visit.childIndex = childIndex;
        visit.type = ElementType.node;
        visit.id = resolved.reference.id;
        visit.depth = depth;
        visit.resolution = resolved.state;
        visit.target = resolved.target;

        ++status.visits;
        updateDepth(depth, status);

        status.control = visitor(visit);
        if (status.control != 0)
            return true;

        ++childIndex;
    }

    return true;
}

bool walkOwnedRelationChildren(
    ref const OwnedDataset dataset,
    ref OwnedDatasetIndex index,
    size_t relationIndex,
    size_t depth,
    ref TopologyTraversalWorkspace workspace,
    TopologyTraversalLimits limits,
    scope int delegate(scope ref const OwnedChildVisit) @safe visitor,
    ref TopologyTraversalStatus status)
    @safe
{
    if (relationIndex >= dataset.relations.length)
    {
        status.error = TopologyTraversalError.staleIndex;
        return false;
    }

    ref const relation = dataset.relations[relationIndex];
    auto members = index.resolveMembers(relation);
    size_t childIndex;

    while (!members.empty)
    {
        auto resolved = members.front;
        members.popFront();

        if (!reserveVisit(
                resolved.member.type,
                resolved.member.id,
                depth,
                limits,
                status))
            return false;

        OwnedChildVisit visit;
        visit.parentType = ElementType.relation;
        visit.parentId = relation.id;
        visit.childIndex = childIndex;
        visit.type = resolved.member.type;
        visit.id = resolved.member.id;
        visit.depth = depth;
        visit.resolution = resolved.state;
        visit.targetIndex = resolved.targetIndex;
        visit.relationPreviouslyExpanded =
            visit.type == ElementType.relation &&
            resolved.resolved &&
            workspace.relationSeen(visit.id);

        ++status.visits;
        updateDepth(depth, status);

        status.control = visitor(visit);
        if (status.control != 0)
            return true;

        if (resolved.resolved)
        {
            if (visit.type == ElementType.way)
            {
                if (visit.targetIndex >= dataset.ways.length ||
                    dataset.ways[visit.targetIndex].id != visit.id)
                {
                    status.error = TopologyTraversalError.staleIndex;
                    return false;
                }

                if (!walkOwnedWayNodes(
                        index,
                        dataset.ways[visit.targetIndex],
                        depth + 1,
                        limits,
                        visitor,
                        status))
                    return false;

                if (status.control != 0)
                    return true;
            }
            else if (visit.type == ElementType.relation &&
                     !visit.relationPreviouslyExpanded)
            {
                if (depth >= limits.maxDepth)
                {
                    status.error = TopologyTraversalError.depthLimit;
                    status.type = visit.type;
                    status.id = visit.id;
                    status.hasObject = true;
                    return false;
                }

                if (status.relationsExpanded >=
                    limits.maxRelations)
                {
                    status.error =
                        TopologyTraversalError.relationLimit;
                    status.type = visit.type;
                    status.id = visit.id;
                    status.hasObject = true;
                    return false;
                }

                if (visit.targetIndex >=
                        dataset.relations.length ||
                    dataset.relations[
                        visit.targetIndex].id != visit.id)
                {
                    status.error = TopologyTraversalError.staleIndex;
                    return false;
                }

                workspace.markRelation(visit.id);
                ++status.relationsExpanded;

                if (!walkOwnedRelationChildren(
                        dataset,
                        index,
                        visit.targetIndex,
                        depth + 1,
                        workspace,
                        limits,
                        visitor,
                        status))
                    return false;

                if (status.control != 0)
                    return true;
            }
        }

        ++childIndex;
    }

    return true;
}

bool walkOwnedWayNodes(
    ref OwnedDatasetIndex index,
    ref const OwnedWay way,
    size_t depth,
    TopologyTraversalLimits limits,
    scope int delegate(scope ref const OwnedChildVisit) @safe visitor,
    ref TopologyTraversalStatus status)
    @safe
{
    if (depth > limits.maxDepth)
    {
        status.error = TopologyTraversalError.depthLimit;
        status.type = ElementType.way;
        status.id = way.id;
        status.hasObject = true;
        return false;
    }

    auto nodes = index.resolveNodes(way);
    size_t childIndex;

    while (!nodes.empty)
    {
        auto resolved = nodes.front;
        nodes.popFront();

        if (!reserveVisit(
                ElementType.node,
                resolved.reference.id,
                depth,
                limits,
                status))
            return false;

        OwnedChildVisit visit;
        visit.parentType = ElementType.way;
        visit.parentId = way.id;
        visit.childIndex = childIndex;
        visit.type = ElementType.node;
        visit.id = resolved.reference.id;
        visit.depth = depth;
        visit.resolution = resolved.state;
        visit.targetIndex = resolved.targetIndex;

        ++status.visits;
        updateDepth(depth, status);

        status.control = visitor(visit);
        if (status.control != 0)
            return true;

        ++childIndex;
    }

    return true;
}

bool reserveVisit(
    ElementType type,
    OsmId id,
    size_t depth,
    TopologyTraversalLimits limits,
    ref TopologyTraversalStatus status)
    @safe pure nothrow @nogc
{
    if (depth > limits.maxDepth)
    {
        status.error = TopologyTraversalError.depthLimit;
        status.type = type;
        status.id = id;
        status.hasObject = true;
        return false;
    }

    if (status.visits >= limits.maxVisits)
    {
        status.error = TopologyTraversalError.visitLimit;
        status.type = type;
        status.id = id;
        status.hasObject = true;
        return false;
    }

    return true;
}

void updateDepth(
    size_t depth,
    ref TopologyTraversalStatus status)
    @safe pure nothrow @nogc
{
    if (depth > status.maxDepthReached)
        status.maxDepthReached = depth;
}

bool emitStoreParent(
    OsmHandle handle,
    ElementType type,
    OsmId id,
    size_t depth,
    TopologyTraversalLimits limits,
    scope int delegate(scope ref const StoreParentVisit) @safe visitor,
    ref TopologyTraversalStatus status)
    @safe
{
    if (!reserveVisit(type, id, depth, limits, status))
        return false;

    StoreParentVisit visit;
    visit.type = type;
    visit.id = id;
    visit.depth = depth;
    visit.target = handle;

    ++status.visits;
    updateDepth(depth, status);

    status.control = visitor(visit);
    return status.control == 0;
}

bool enqueueStoreRelationParent(
    StoreRelationView relation,
    size_t depth,
    ref TopologyTraversalWorkspace workspace,
    TopologyTraversalLimits limits,
    scope int delegate(scope ref const StoreParentVisit) @safe visitor,
    ref TopologyTraversalStatus status)
    @safe
{
    if (workspace.relationSeen(relation.id))
        return true;

    if (depth > limits.maxDepth)
    {
        status.error = TopologyTraversalError.depthLimit;
        status.type = ElementType.relation;
        status.id = relation.id;
        status.hasObject = true;
        return false;
    }

    if (status.relationsExpanded >= limits.maxRelations)
    {
        status.error = TopologyTraversalError.relationLimit;
        status.type = ElementType.relation;
        status.id = relation.id;
        status.hasObject = true;
        return false;
    }

    if (!reserveVisit(
            ElementType.relation,
            relation.id,
            depth,
            limits,
            status))
        return false;

    workspace.markRelation(relation.id);
    ++status.relationsExpanded;

    StoreParentVisit visit;
    visit.type = ElementType.relation;
    visit.id = relation.id;
    visit.depth = depth;
    visit.target = relation.handle;

    ++status.visits;
    updateDepth(depth, status);

    status.control = visitor(visit);
    if (status.control != 0)
        return false;

    workspace._storeRelations ~=
        StoreRelationQueueEntry(
            relation.handle,
            relation.id,
            depth);
    return true;
}

bool emitOwnedParent(
    ElementType type,
    OsmId id,
    size_t targetIndex,
    size_t depth,
    TopologyTraversalLimits limits,
    scope int delegate(scope ref const OwnedParentVisit) @safe visitor,
    ref TopologyTraversalStatus status)
    @safe
{
    if (!reserveVisit(type, id, depth, limits, status))
        return false;

    OwnedParentVisit visit;
    visit.type = type;
    visit.id = id;
    visit.depth = depth;
    visit.targetIndex = targetIndex;

    ++status.visits;
    updateDepth(depth, status);

    status.control = visitor(visit);
    return status.control == 0;
}

bool enqueueOwnedRelationParent(
    ref const OwnedDataset dataset,
    size_t relationIndex,
    size_t depth,
    ref TopologyTraversalWorkspace workspace,
    TopologyTraversalLimits limits,
    scope int delegate(scope ref const OwnedParentVisit) @safe visitor,
    ref TopologyTraversalStatus status)
    @safe
{
    if (relationIndex >= dataset.relations.length)
    {
        status.error = TopologyTraversalError.staleIndex;
        return false;
    }

    ref const relation = dataset.relations[relationIndex];

    if (workspace.relationSeen(relation.id))
        return true;

    if (depth > limits.maxDepth)
    {
        status.error = TopologyTraversalError.depthLimit;
        status.type = ElementType.relation;
        status.id = relation.id;
        status.hasObject = true;
        return false;
    }

    if (status.relationsExpanded >= limits.maxRelations)
    {
        status.error = TopologyTraversalError.relationLimit;
        status.type = ElementType.relation;
        status.id = relation.id;
        status.hasObject = true;
        return false;
    }

    if (!reserveVisit(
            ElementType.relation,
            relation.id,
            depth,
            limits,
            status))
        return false;

    workspace.markRelation(relation.id);
    ++status.relationsExpanded;

    OwnedParentVisit visit;
    visit.type = ElementType.relation;
    visit.id = relation.id;
    visit.depth = depth;
    visit.targetIndex = relationIndex;

    ++status.visits;
    updateDepth(depth, status);

    status.control = visitor(visit);
    if (status.control != 0)
        return false;

    workspace._ownedRelations ~=
        OwnedRelationQueueEntry(
            relationIndex,
            relation.id,
            depth);
    return true;
}

bool validElementType(ElementType type)
    @safe pure nothrow @nogc
{
    return type == ElementType.node ||
           type == ElementType.way ||
           type == ElementType.relation;
}

unittest
{
    import osm.model.owned :
        OwnedNode,
        OwnedNodeRef,
        OwnedRelation,
        OwnedRelationMember,
        OwnedWay;

    auto store = new OsmStore();
    StoreStatus storeStatus;

    OwnedNode node;
    node.id = 1;
    OsmHandle nodeHandle;
    assert(store.add(node, nodeHandle, storeStatus));

    OwnedWay way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(1);
    way.nodes ~= OwnedNodeRef(1);
    OsmHandle wayHandle;
    assert(store.add(way, wayHandle, storeStatus));

    OwnedRelation a;
    a.id = 20;
    a.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        null);
    a.members ~= OwnedRelationMember(
        ElementType.relation,
        21,
        null);
    OsmHandle aHandle;
    assert(store.add(a, aHandle, storeStatus));

    OwnedRelation b;
    b.id = 21;
    b.members ~= OwnedRelationMember(
        ElementType.relation,
        20,
        null);
    b.members ~= OwnedRelationMember(
        ElementType.node,
        999,
        null);
    OsmHandle bHandle;
    assert(store.add(b, bHandle, storeStatus));

    assert(store.replace(aHandle, a, storeStatus));

    TopologyTraversalWorkspace workspace;
    TopologyTraversalStatus status;
    TopologyTraversalLimits limits;

    StoreChildVisit[] visits;
    int collect(scope ref const StoreChildVisit visit) @safe
    {
        visits ~= visit;
        return 0;
    }

    assert(walkRelationClosure(
        store,
        aHandle,
        workspace,
        limits,
        &collect,
        status));
    assert(status.completed);
    assert(status.relationsExpanded == 2);

    assert(visits.length == 6);
    assert(visits[0].type == ElementType.way);
    assert(visits[1].type == ElementType.node);
    assert(visits[2].type == ElementType.node);
    assert(visits[1].id == 1 && visits[2].id == 1);
    assert(visits[3].type == ElementType.relation);
    assert(visits[3].id == 21);
    assert(visits[4].type == ElementType.relation);
    assert(visits[4].id == 20);
    assert(visits[4].relationPreviouslyExpanded);
    assert(visits[5].resolution ==
        ReferenceResolutionState.unresolvedPositive);
}

unittest
{
    import osm.model.owned :
        OwnedNode,
        OwnedNodeRef,
        OwnedRelation,
        OwnedRelationMember,
        OwnedWay;

    OwnedDataset dataset;

    OwnedNode node;
    node.id = 1;
    dataset.nodes ~= node;

    OwnedWay way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(1);
    way.nodes ~= OwnedNodeRef(1);
    dataset.ways ~= way;

    OwnedRelation a;
    a.id = 20;
    a.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        null);
    a.members ~= OwnedRelationMember(
        ElementType.relation,
        21,
        null);
    dataset.relations ~= a;

    OwnedRelation b;
    b.id = 21;
    b.members ~= OwnedRelationMember(
        ElementType.relation,
        20,
        null);
    b.members ~= OwnedRelationMember(
        ElementType.node,
        999,
        null);
    dataset.relations ~= b;

    OwnedDatasetIndex index;
    import osm.validate : DatasetValidationIssue;
    DatasetValidationIssue issue;
    assert(index.build(dataset, issue));

    TopologyTraversalWorkspace workspace;
    TopologyTraversalStatus status;
    TopologyTraversalLimits limits;

    OwnedChildVisit[] visits;
    int collect(scope ref const OwnedChildVisit visit) @safe
    {
        visits ~= visit;
        return 0;
    }

    assert(walkRelationClosure(
        dataset,
        index,
        20,
        workspace,
        limits,
        &collect,
        status));
    assert(status.completed);
    assert(status.relationsExpanded == 2);
    assert(visits.length == 6);
    assert(visits[4].relationPreviouslyExpanded);
    assert(visits[5].resolution ==
        ReferenceResolutionState.unresolvedPositive);
}

unittest
{
    import osm.model.owned :
        OwnedNode,
        OwnedNodeRef,
        OwnedRelation,
        OwnedRelationMember,
        OwnedWay;

    auto store = new OsmStore();
    StoreStatus storeStatus;

    OwnedNode node;
    node.id = 1;
    OsmHandle nodeHandle;
    assert(store.add(node, nodeHandle, storeStatus));

    OwnedWay way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(1);
    OsmHandle wayHandle;
    assert(store.add(way, wayHandle, storeStatus));

    OwnedRelation direct;
    direct.id = 20;
    direct.members ~= OwnedRelationMember(
        ElementType.node,
        1,
        null);
    OsmHandle directHandle;
    assert(store.add(direct, directHandle, storeStatus));

    OwnedRelation viaWay;
    viaWay.id = 21;
    viaWay.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        null);
    OsmHandle viaWayHandle;
    assert(store.add(viaWay, viaWayHandle, storeStatus));

    OwnedRelation parent;
    parent.id = 22;
    parent.members ~= OwnedRelationMember(
        ElementType.relation,
        20,
        null);
    parent.members ~= OwnedRelationMember(
        ElementType.relation,
        21,
        null);
    OsmHandle parentHandle;
    assert(store.add(parent, parentHandle, storeStatus));

    TopologyTraversalWorkspace workspace;
    TopologyTraversalStatus status;
    TopologyTraversalLimits limits;

    StoreParentVisit[] visits;
    int collect(scope ref const StoreParentVisit visit) @safe
    {
        visits ~= visit;
        return 0;
    }

    assert(walkParentClosure(
        store,
        ElementType.node,
        1,
        workspace,
        limits,
        &collect,
        status));
    assert(status.completed);

    assert(visits.length == 4);
    assert(visits[0].type == ElementType.way);
    assert(visits[0].id == 10);
    assert(visits[1].type == ElementType.relation);
    assert(visits[1].id == 20);
    assert(visits[2].type == ElementType.relation);
    assert(visits[2].id == 21);
    assert(visits[3].type == ElementType.relation);
    assert(visits[3].id == 22);
}

unittest
{
    import osm.model.owned :
        OwnedNode,
        OwnedNodeRef,
        OwnedRelation,
        OwnedRelationMember,
        OwnedWay;

    OwnedDataset dataset;

    OwnedNode node;
    node.id = 1;
    dataset.nodes ~= node;

    OwnedWay way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(1);
    dataset.ways ~= way;

    OwnedRelation direct;
    direct.id = 20;
    direct.members ~= OwnedRelationMember(
        ElementType.node,
        1,
        null);
    dataset.relations ~= direct;

    OwnedRelation viaWay;
    viaWay.id = 21;
    viaWay.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        null);
    dataset.relations ~= viaWay;

    OwnedRelation parent;
    parent.id = 22;
    parent.members ~= OwnedRelationMember(
        ElementType.relation,
        20,
        null);
    parent.members ~= OwnedRelationMember(
        ElementType.relation,
        21,
        null);
    dataset.relations ~= parent;

    OwnedDatasetIndex index;
    import osm.validate : DatasetValidationIssue;
    DatasetValidationIssue issue;
    assert(index.build(dataset, issue));

    TopologyTraversalWorkspace workspace;
    TopologyTraversalStatus status;
    TopologyTraversalLimits limits;

    OwnedParentVisit[] visits;
    int collect(scope ref const OwnedParentVisit visit) @safe
    {
        visits ~= visit;
        return 0;
    }

    assert(walkParentClosure(
        dataset,
        index,
        ElementType.node,
        1,
        workspace,
        limits,
        &collect,
        status));
    assert(status.completed);
    assert(visits.length == 4);
    assert(visits[0].type == ElementType.way);
    assert(visits[0].id == 10);
    assert(visits[1].id == 20);
    assert(visits[2].id == 21);
    assert(visits[3].id == 22);
}

unittest
{
    import osm.model.owned :
        OwnedRelation,
        OwnedRelationMember;

    OwnedDataset dataset;

    OwnedRelation a;
    a.id = 1;
    a.members ~= OwnedRelationMember(
        ElementType.relation,
        2,
        null);
    dataset.relations ~= a;

    OwnedRelation b;
    b.id = 2;
    b.members ~= OwnedRelationMember(
        ElementType.node,
        99,
        null);
    dataset.relations ~= b;

    OwnedDatasetIndex index;
    import osm.validate : DatasetValidationIssue;
    DatasetValidationIssue issue;
    assert(index.build(dataset, issue));

    TopologyTraversalWorkspace workspace;
    TopologyTraversalStatus status;

    TopologyTraversalLimits tight;
    tight.maxDepth = 1;

    int noop(scope ref const OwnedChildVisit visit) @safe
    {
        return 0;
    }

    assert(!walkRelationClosure(
        dataset,
        index,
        1,
        workspace,
        tight,
        &noop,
        status));
    assert(status.error == TopologyTraversalError.depthLimit);

    TopologyTraversalLimits limits;
    int stop(scope ref const OwnedChildVisit visit) @safe
    {
        return 7;
    }

    assert(walkRelationClosure(
        dataset,
        index,
        1,
        workspace,
        limits,
        &stop,
        status));
    assert(status.ok);
    assert(!status.completed);
    assert(status.control == 7);
}
