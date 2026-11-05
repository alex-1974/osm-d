/**
 * Ordered OSM reference resolution for owned datasets and OsmStore.
 *
 * Resolution is topology, not geometry. Original order and duplicates are
 * preserved. Results carry handles or array indices instead of materializing
 * complete objects.
 */
module osm.topology.resolution;

import osm.model.owned :
    OwnedDataset,
    OwnedNodeRef,
    OwnedRelation,
    OwnedRelationMember,
    OwnedWay;
import osm.store :
    OsmHandle,
    OsmStore,
    StoreNodeRefRange,
    StoreRelationMemberRange,
    StoreRelationView,
    StoreWayView;
import osm.validation.dataset :
    DatasetValidationError,
    DatasetValidationIssue,
    DatasetValidationMode,
    validateDataset;
import osm.view.element : ElementType, OsmId;
import osm.view.node_ref : NodeRefView;
import osm.view.relation_member : RelationMemberView;

/** Outcome of resolving one typed OSM reference. */
enum ReferenceResolutionState : ubyte
{
    none,
    resolved,
    unresolvedPositive,
    unresolvedLocal,
    zeroReference,
    invalidType,
}

/** One ordered Way node reference resolved through an OsmStore. */
struct StoreResolvedNodeRef
{
    NodeRefView reference;
    ReferenceResolutionState state;
    OsmHandle target;

    @property bool resolved() const @safe pure nothrow @nogc
    {
        return state == ReferenceResolutionState.resolved;
    }
}

/** One ordered Relation member resolved through an OsmStore. */
struct StoreResolvedRelationMember
{
    RelationMemberView member;
    ReferenceResolutionState state;
    OsmHandle target;

    @property bool resolved() const @safe pure nothrow @nogc
    {
        return state == ReferenceResolutionState.resolved;
    }
}

/** Lazy ordered resolution of one Store Way's node references. */
struct StoreResolvedNodeRefRange
{
private:
    OsmStore _store;
    StoreNodeRefRange _references;

    this(OsmStore store, StoreNodeRefRange references)
        @safe nothrow @nogc
    {
        _store = store;
        _references = references;
    }

public:
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _references.empty;
    }

    @property StoreResolvedNodeRef front() @safe nothrow @nogc
    in (!empty)
    {
        auto reference = _references.front;
        StoreResolvedNodeRef result;
        result.reference = reference;
        result.state = classifyStoreReference(
            _store,
            ElementType.node,
            reference.id,
            result.target);
        return result;
    }

    void popFront() @safe nothrow @nogc
    in (!empty)
    {
        _references.popFront();
    }

    @property size_t length() const @safe pure nothrow @nogc
    {
        return _references.length;
    }
}

/** Lazy ordered resolution of one Store Relation's members. */
struct StoreResolvedRelationMemberRange
{
private:
    OsmStore _store;
    StoreRelationMemberRange _members;

    this(OsmStore store, StoreRelationMemberRange members)
        @safe nothrow @nogc
    {
        _store = store;
        _members = members;
    }

public:
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _members.empty;
    }

    @property StoreResolvedRelationMember front() @safe nothrow @nogc
    in (!empty)
    {
        auto member = _members.front;
        StoreResolvedRelationMember result;
        result.member = member;
        result.state = classifyStoreReference(
            _store,
            member.type,
            member.id,
            result.target);
        return result;
    }

    void popFront() @safe nothrow @nogc
    in (!empty)
    {
        _members.popFront();
    }

    @property size_t length() const @safe pure nothrow @nogc
    {
        return _members.length;
    }
}

/**
 * Resolve one Store Way's node references in original order.
 *
 * UFCS form: store.resolveNodes(way).
 */
StoreResolvedNodeRefRange resolveNodes(
    OsmStore store,
    StoreWayView way)
    @safe nothrow @nogc
{
    return StoreResolvedNodeRefRange(store, way.nodes);
}

/** Resolve one Store Relation's members in original order. */
StoreResolvedRelationMemberRange resolveMembers(
    OsmStore store,
    StoreRelationView relation)
    @safe nothrow @nogc
{
    return StoreResolvedRelationMemberRange(store, relation.members);
}

/**
 * Explicit reusable primary index for one OwnedDataset identity layout.
 *
 * The index does not retain or copy the dataset. Rebuild it after mutations
 * that change IDs, element ordering, insertion, or removal.
 */
struct OwnedDatasetIndex
{
private:
    size_t[OsmId] _nodes;
    size_t[OsmId] _ways;
    size_t[OsmId] _relations;

public:
    void clear() @safe nothrow
    {
        _nodes = null;
        _ways = null;
        _relations = null;
    }

    /**
     * Build typed ID-to-array indices transactionally.
     *
     * ID zero and duplicate IDs within one element type fail. References are
     * not inspected here.
     */
    bool build(
        ref const OwnedDataset dataset,
        out DatasetValidationIssue issue)
        @safe
    {
        clear();
        issue = DatasetValidationIssue.init;

        size_t[OsmId] nodes;
        size_t[OsmId] ways;
        size_t[OsmId] relations;

        foreach (i, ref const node; dataset.nodes)
        {
            if (!addIndexedIdentity(
                    ElementType.node,
                    node.id,
                    i,
                    nodes,
                    issue))
                return false;
        }

        foreach (i, ref const way; dataset.ways)
        {
            if (!addIndexedIdentity(
                    ElementType.way,
                    way.id,
                    i,
                    ways,
                    issue))
                return false;
        }

        foreach (i, ref const relation; dataset.relations)
        {
            if (!addIndexedIdentity(
                    ElementType.relation,
                    relation.id,
                    i,
                    relations,
                    issue))
                return false;
        }

        _nodes = nodes;
        _ways = ways;
        _relations = relations;
        return true;
    }

    /** Find one typed element array index. */
    bool find(ElementType type, OsmId id, out size_t index)
        @safe nothrow
    {
        index = 0;

        if (!validReferenceType(type))
            return false;

        final switch (type)
        {
            case ElementType.node:
                if (auto p = id in _nodes)
                {
                    index = *p;
                    return true;
                }
                return false;

            case ElementType.way:
                if (auto p = id in _ways)
                {
                    index = *p;
                    return true;
                }
                return false;

            case ElementType.relation:
                if (auto p = id in _relations)
                {
                    index = *p;
                    return true;
                }
                return false;
        }
    }

    /** Resolve one owned Way's node references lazily. */
    OwnedResolvedNodeRefRange resolveNodes(ref const OwnedWay way)
        @safe nothrow
    {
        return OwnedResolvedNodeRefRange(way.nodes, _nodes);
    }

    /** Resolve one owned Relation's members lazily. */
    OwnedResolvedRelationMemberRange resolveMembers(
        ref const OwnedRelation relation)
        @safe nothrow
    {
        return OwnedResolvedRelationMemberRange(
            relation.members,
            _nodes,
            _ways,
            _relations);
    }
}

/** One owned Way node reference resolved to a dataset Node index. */
struct OwnedResolvedNodeRef
{
    OwnedNodeRef reference;
    ReferenceResolutionState state;
    size_t targetIndex;

    @property bool resolved() const @safe pure nothrow @nogc
    {
        return state == ReferenceResolutionState.resolved;
    }
}

/** One owned Relation member resolved to a typed dataset array index. */
struct OwnedResolvedRelationMember
{
    OwnedRelationMember member;
    ReferenceResolutionState state;
    size_t targetIndex;

    @property bool resolved() const @safe pure nothrow @nogc
    {
        return state == ReferenceResolutionState.resolved;
    }
}

/** Lazy ordered resolution of OwnedWay node references. */
struct OwnedResolvedNodeRefRange
{
private:
    const(OwnedNodeRef)[] _references;
    size_t[OsmId] _nodes;
    size_t _position;

    this(const(OwnedNodeRef)[] references, size_t[OsmId] nodes)
        @safe nothrow
    {
        _references = references;
        _nodes = nodes;
    }

public:
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _position >= _references.length;
    }

    @property OwnedResolvedNodeRef front() @safe nothrow
    in (!empty)
    {
        auto reference = _references[_position];
        OwnedResolvedNodeRef result;
        result.reference = reference;
        result.state = classifyIndexedNode(
            reference.id,
            _nodes,
            result.targetIndex);
        return result;
    }

    void popFront() @safe pure nothrow @nogc
    in (!empty)
    {
        ++_position;
    }

    @property size_t length() const @safe pure nothrow @nogc
    {
        return _references.length - _position;
    }
}

/** Lazy ordered resolution of OwnedRelation members. */
struct OwnedResolvedRelationMemberRange
{
private:
    const(OwnedRelationMember)[] _members;
    size_t[OsmId] _nodes;
    size_t[OsmId] _ways;
    size_t[OsmId] _relations;
    size_t _position;

    this(
        const(OwnedRelationMember)[] members,
        size_t[OsmId] nodes,
        size_t[OsmId] ways,
        size_t[OsmId] relations)
        @safe nothrow
    {
        _members = members;
        _nodes = nodes;
        _ways = ways;
        _relations = relations;
    }

public:
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _position >= _members.length;
    }

    @property OwnedResolvedRelationMember front() @safe nothrow
    in (!empty)
    {
        auto member = _members[_position];
        OwnedResolvedRelationMember result;
        result.member = member;
        result.state = classifyIndexedMember(
            member.type,
            member.id,
            _nodes,
            _ways,
            _relations,
            result.targetIndex);
        return result;
    }

    void popFront() @safe pure nothrow @nogc
    in (!empty)
    {
        ++_position;
    }

    @property size_t length() const @safe pure nothrow @nogc
    {
        return _members.length - _position;
    }
}

private:

bool addIndexedIdentity(
    ElementType type,
    OsmId id,
    size_t index,
    ref size_t[OsmId] ids,
    ref DatasetValidationIssue issue)
    @safe
{
    if (id == 0)
    {
        issue.error = DatasetValidationError.zeroElementId;
        issue.elementType = type;
        issue.elementId = id;
        issue.elementIndex = index;
        issue.hasElement = true;
        return false;
    }

    if (id in ids)
    {
        issue.error = DatasetValidationError.duplicateElementId;
        issue.elementType = type;
        issue.elementId = id;
        issue.elementIndex = index;
        issue.hasElement = true;
        return false;
    }

    ids[id] = index;
    return true;
}

ReferenceResolutionState classifyStoreReference(
    OsmStore store,
    ElementType type,
    OsmId id,
    out OsmHandle target)
    @safe nothrow @nogc
{
    target = OsmHandle.init;

    if (!validReferenceType(type))
        return ReferenceResolutionState.invalidType;
    if (id == 0)
        return ReferenceResolutionState.zeroReference;

    if (store !is null && store.find(type, id, target))
        return ReferenceResolutionState.resolved;

    return id < 0
        ? ReferenceResolutionState.unresolvedLocal
        : ReferenceResolutionState.unresolvedPositive;
}

ReferenceResolutionState classifyIndexedNode(
    OsmId id,
    ref size_t[OsmId] nodes,
    out size_t targetIndex)
    @safe nothrow
{
    targetIndex = 0;

    if (id == 0)
        return ReferenceResolutionState.zeroReference;

    if (auto p = id in nodes)
    {
        targetIndex = *p;
        return ReferenceResolutionState.resolved;
    }

    return id < 0
        ? ReferenceResolutionState.unresolvedLocal
        : ReferenceResolutionState.unresolvedPositive;
}

ReferenceResolutionState classifyIndexedMember(
    ElementType type,
    OsmId id,
    ref size_t[OsmId] nodes,
    ref size_t[OsmId] ways,
    ref size_t[OsmId] relations,
    out size_t targetIndex)
    @safe nothrow
{
    targetIndex = 0;

    if (!validReferenceType(type))
        return ReferenceResolutionState.invalidType;
    if (id == 0)
        return ReferenceResolutionState.zeroReference;

    size_t* p;
    final switch (type)
    {
        case ElementType.node:
            p = id in nodes;
            break;
        case ElementType.way:
            p = id in ways;
            break;
        case ElementType.relation:
            p = id in relations;
            break;
    }

    if (p !is null)
    {
        targetIndex = *p;
        return ReferenceResolutionState.resolved;
    }

    return id < 0
        ? ReferenceResolutionState.unresolvedLocal
        : ReferenceResolutionState.unresolvedPositive;
}

bool validReferenceType(ElementType type)
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
        OwnedRelation,
        OwnedRelationMember,
        OwnedWay;
    import osm.store : StoreStatus;

    auto store = new OsmStore();
    StoreStatus status;

    OwnedNode node;
    node.id = 1;
    OsmHandle nodeHandle;
    assert(store.add(node, nodeHandle, status));

    OwnedWay way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(1);
    way.nodes ~= OwnedNodeRef(999);
    way.nodes ~= OwnedNodeRef(1);

    OsmHandle wayHandle;
    assert(store.add(way, wayHandle, status));

    StoreWayView wayView;
    assert(store.way(wayHandle, wayView, status));

    auto resolvedNodes = store.resolveNodes(wayView);
    assert(resolvedNodes.length == 3);
    assert(resolvedNodes.front.reference.id == 1);
    assert(resolvedNodes.front.resolved);
    assert(resolvedNodes.front.target == nodeHandle);
    resolvedNodes.popFront();

    assert(resolvedNodes.front.reference.id == 999);
    assert(resolvedNodes.front.state ==
        ReferenceResolutionState.unresolvedPositive);
    resolvedNodes.popFront();

    assert(resolvedNodes.front.reference.id == 1);
    assert(resolvedNodes.front.target == nodeHandle);

    OwnedRelation relation;
    relation.id = 20;
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        null);
    relation.members ~= OwnedRelationMember(
        ElementType.node,
        -7,
        null);

    OsmHandle relationHandle;
    assert(store.add(relation, relationHandle, status));

    StoreRelationView relationView;
    assert(store.relation(relationHandle, relationView, status));
    auto members = store.resolveMembers(relationView);
    assert(members.front.resolved);
    assert(members.front.target == wayHandle);
    members.popFront();
    assert(members.front.state ==
        ReferenceResolutionState.unresolvedLocal);
}

unittest
{
    import osm.model.owned :
        OwnedNode,
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
    way.nodes ~= OwnedNodeRef(999);
    way.nodes ~= OwnedNodeRef(1);
    dataset.ways ~= way;

    OwnedRelation relation;
    relation.id = 20;
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        null);
    relation.members ~= OwnedRelationMember(
        ElementType.node,
        -7,
        null);
    dataset.relations ~= relation;

    OwnedDatasetIndex index;
    DatasetValidationIssue issue;
    assert(index.build(
        dataset,
        issue));

    auto brokenMembers = index.resolveMembers(dataset.relations[0]);
    brokenMembers.popFront();
    assert(brokenMembers.front.state ==
        ReferenceResolutionState.unresolvedLocal);

    DatasetValidationIssue validationIssue;
    assert(!validateDataset(
        dataset,
        DatasetValidationMode.partial,
        validationIssue));
    assert(validationIssue.error ==
        DatasetValidationError.unresolvedLocalReference);

    dataset.relations[0].members[1].id = 999;
    assert(index.build(
        dataset,
        issue));

    auto nodes = index.resolveNodes(dataset.ways[0]);
    assert(nodes.front.resolved);
    assert(nodes.front.targetIndex == 0);
    nodes.popFront();
    assert(nodes.front.state ==
        ReferenceResolutionState.unresolvedPositive);
    nodes.popFront();
    assert(nodes.front.resolved);
    assert(nodes.front.targetIndex == 0);

    auto members = index.resolveMembers(dataset.relations[0]);
    assert(members.front.resolved);
    assert(members.front.targetIndex == 0);
    members.popFront();
    assert(members.front.state ==
        ReferenceResolutionState.unresolvedPositive);
}
