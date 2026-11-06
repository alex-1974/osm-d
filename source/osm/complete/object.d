/**
 * Borrowed complete OSM object projections.
 *
 * This layer enriches M15 identity/reference resolution with the actual
 * resolved semantic child object while preserving source order, duplicates
 * and explicit missing-reference state.
 */
module osm.complete.object;

import osm.model.owned :
    OwnedDataset,
    OwnedMetadata,
    OwnedNode,
    OwnedNodeRef,
    OwnedRelation,
    OwnedRelationMember,
    OwnedTag,
    OwnedWay;
import osm.store :
    OsmHandle,
    OsmStore,
    StoreNodeView,
    StoreRelationView,
    StoreStatus,
    StoreWayView;
import osm.topology :
    OwnedDatasetIndex,
    OwnedResolvedNodeRefRange,
    OwnedResolvedRelationMemberRange,
    ReferenceResolutionState,
    StoreResolvedNodeRefRange,
    StoreResolvedRelationMemberRange,
    resolveMembers,
    resolveNodes;
import osm.view.element : ElementType, OsmId;
import osm.view.location : LocationView;
import osm.view.node_ref : NodeRefView;
import osm.view.relation_member : RelationMemberView;

/** Aggregate completeness of one directly resolved OSM object. */
enum CompleteObjectState : ubyte
{
    notInspected,
    complete,
    partial,
    invalid,
}

/** First direct child that prevents a complete object from being complete. */
struct CompleteObjectStatus
{
    CompleteObjectState state = CompleteObjectState.notInspected;
    ReferenceResolutionState issue;
    size_t childIndex;
    ElementType referenceType;
    OsmId referenceId;
    bool hasIssue;

    @property bool complete() const @safe pure nothrow @nogc
    {
        return state == CompleteObjectState.complete;
    }
}

/** Exact OSM-native latitude/longitude bounds in signed nanodegrees. */
struct LocationBounds
{
private:
    bool _hasValue;
    long _minLatitudeNanodegrees;
    long _minLongitudeNanodegrees;
    long _maxLatitudeNanodegrees;
    long _maxLongitudeNanodegrees;

public:
    @property bool empty() const @safe pure nothrow @nogc
    {
        return !_hasValue;
    }

    @property long minLatitudeNanodegrees() const
        @safe pure nothrow @nogc
    in (_hasValue)
    {
        return _minLatitudeNanodegrees;
    }

    @property long minLongitudeNanodegrees() const
        @safe pure nothrow @nogc
    in (_hasValue)
    {
        return _minLongitudeNanodegrees;
    }

    @property long maxLatitudeNanodegrees() const
        @safe pure nothrow @nogc
    in (_hasValue)
    {
        return _maxLatitudeNanodegrees;
    }

    @property long maxLongitudeNanodegrees() const
        @safe pure nothrow @nogc
    in (_hasValue)
    {
        return _maxLongitudeNanodegrees;
    }

    void include(LocationView location) @safe pure nothrow @nogc
    {
        const lat = location.latitudeNanodegrees;
        const lon = location.longitudeNanodegrees;

        if (!_hasValue)
        {
            _hasValue = true;
            _minLatitudeNanodegrees = lat;
            _maxLatitudeNanodegrees = lat;
            _minLongitudeNanodegrees = lon;
            _maxLongitudeNanodegrees = lon;
            return;
        }

        if (lat < _minLatitudeNanodegrees)
            _minLatitudeNanodegrees = lat;
        if (lat > _maxLatitudeNanodegrees)
            _maxLatitudeNanodegrees = lat;
        if (lon < _minLongitudeNanodegrees)
            _minLongitudeNanodegrees = lon;
        if (lon > _maxLongitudeNanodegrees)
            _maxLongitudeNanodegrees = lon;
    }
}

/** One Store Way Node reference enriched with the live resolved Node view. */
struct StoreCompleteNode
{
    NodeRefView reference;
    ReferenceResolutionState state;
    OsmHandle target;
    StoreNodeView node;

    @property bool resolved() const @safe pure nothrow @nogc
    {
        return state == ReferenceResolutionState.resolved;
    }

    @property LocationView location() const @safe pure nothrow @nogc
    in (resolved)
    {
        return node.location;
    }
}

/** Lazy ordered complete Node range for one Store Way. */
struct StoreCompleteNodeRange
{
private:
    OsmStore _store;
    StoreResolvedNodeRefRange _resolved;

    this(OsmStore store, StoreResolvedNodeRefRange resolved)
        @safe nothrow @nogc
    {
        _store = store;
        _resolved = resolved;
    }

public:
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _resolved.empty;
    }

    @property StoreCompleteNode front() @safe nothrow @nogc
    in (!empty)
    {
        auto value = _resolved.front;

        StoreCompleteNode result;
        result.reference = value.reference;
        result.state = value.state;
        result.target = value.target;

        if (value.resolved)
        {
            StoreStatus status;
            if (!_store.node(value.target, result.node, status))
            {
                result.target = OsmHandle.init;
                result.state = value.reference.id < 0
                    ? ReferenceResolutionState.unresolvedLocal
                    : ReferenceResolutionState.unresolvedPositive;
            }
        }

        return result;
    }

    void popFront() @safe nothrow @nogc
    in (!empty)
    {
        _resolved.popFront();
    }

    @property size_t length() const @safe pure nothrow @nogc
    {
        return _resolved.length;
    }
}

/** Borrowed complete projection of one Store Way. */
struct StoreCompleteWayView
{
    StoreWayView source;
    StoreCompleteNodeRange nodes;

    @property bool isClosed() @safe nothrow @nogc
    {
        return isClosedWay(source);
    }
}

/** One Store Relation member enriched with its live typed target view. */
struct StoreCompleteRelationMember
{
    RelationMemberView member;
    ReferenceResolutionState state;
    OsmHandle target;

    StoreNodeView node;
    StoreWayView way;
    StoreRelationView relation;

    @property bool resolved() const @safe pure nothrow @nogc
    {
        return state == ReferenceResolutionState.resolved;
    }
}

/** Lazy ordered complete member range for one Store Relation. */
struct StoreCompleteRelationMemberRange
{
private:
    OsmStore _store;
    StoreResolvedRelationMemberRange _resolved;

    this(OsmStore store, StoreResolvedRelationMemberRange resolved)
        @safe nothrow @nogc
    {
        _store = store;
        _resolved = resolved;
    }

public:
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _resolved.empty;
    }

    @property StoreCompleteRelationMember front() @safe nothrow @nogc
    in (!empty)
    {
        auto value = _resolved.front;

        StoreCompleteRelationMember result;
        result.member = value.member;
        result.state = value.state;
        result.target = value.target;

        if (!value.resolved)
            return result;

        StoreStatus status;
        bool ok;

        final switch (value.member.type)
        {
            case ElementType.node:
                ok = _store.node(value.target, result.node, status);
                break;
            case ElementType.way:
                ok = _store.way(value.target, result.way, status);
                break;
            case ElementType.relation:
                ok = _store.relation(
                    value.target,
                    result.relation,
                    status);
                break;
        }

        if (!ok)
        {
            result.target = OsmHandle.init;
            result.state = value.member.id < 0
                ? ReferenceResolutionState.unresolvedLocal
                : ReferenceResolutionState.unresolvedPositive;
        }

        return result;
    }

    void popFront() @safe nothrow @nogc
    in (!empty)
    {
        _resolved.popFront();
    }

    @property size_t length() const @safe pure nothrow @nogc
    {
        return _resolved.length;
    }
}

/** Borrowed complete projection of one Store Relation. */
struct StoreCompleteRelationView
{
    StoreRelationView source;
    StoreCompleteRelationMemberRange members;
}

/**
 * Read-only typed target view over an OwnedDataset.
 *
 * The view retains slices to the dataset arrays and a typed target index. It
 * does not copy child arrays. Rebuild/recreate it after topology-changing
 * dataset mutation according to OwnedDatasetIndex rules.
 */
struct OwnedElementView
{
private:
    ElementType _type;
    size_t _index;
    const(OwnedNode)[] _nodes;
    const(OwnedWay)[] _ways;
    const(OwnedRelation)[] _relations;
    bool _valid;

package(osm.complete):
    this(
        ElementType type,
        size_t index,
        const(OwnedNode)[] nodes,
        const(OwnedWay)[] ways,
        const(OwnedRelation)[] relations)
        @safe nothrow
    {
        _type = type;
        _index = index;
        _nodes = nodes;
        _ways = ways;
        _relations = relations;
        _valid = true;
    }

public:
    @property bool valid() const @safe pure nothrow @nogc
    {
        return _valid;
    }

    @property ElementType type() const @safe pure nothrow @nogc
    in (_valid)
    {
        return _type;
    }

    @property size_t index() const @safe pure nothrow @nogc
    in (_valid)
    {
        return _index;
    }

    @property ref const(OwnedNode) node() return @safe nothrow @nogc
    in (_valid && _type == ElementType.node && _index < _nodes.length)
    {
        return _nodes[_index];
    }

    @property ref const(OwnedWay) way() return @safe nothrow @nogc
    in (_valid && _type == ElementType.way && _index < _ways.length)
    {
        return _ways[_index];
    }

    @property ref const(OwnedRelation) relation() return @safe nothrow @nogc
    in (_valid &&
        _type == ElementType.relation &&
        _index < _relations.length)
    {
        return _relations[_index];
    }
}

/** One Owned Way Node reference enriched with resolved Node semantics. */
struct OwnedCompleteNode
{
    OwnedNodeRef reference;
    ReferenceResolutionState state;
    size_t targetIndex;

    LocationView location;
    OwnedMetadata metadata;
    const(OwnedTag)[] tags;

    @property bool resolved() const @safe pure nothrow @nogc
    {
        return state == ReferenceResolutionState.resolved;
    }
}

/** Lazy ordered complete Node range for one Owned Way. */
struct OwnedCompleteNodeRange
{
private:
    const(OwnedNode)[] _nodes;
    OwnedResolvedNodeRefRange _resolved;

    this(
        const(OwnedNode)[] nodes,
        OwnedResolvedNodeRefRange resolved)
        @safe nothrow
    {
        _nodes = nodes;
        _resolved = resolved;
    }

public:
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _resolved.empty;
    }

    @property OwnedCompleteNode front() @safe nothrow
    in (!empty)
    {
        auto value = _resolved.front;

        OwnedCompleteNode result;
        result.reference = value.reference;
        result.state = value.state;
        result.targetIndex = value.targetIndex;

        if (value.resolved)
        {
            if (value.targetIndex >= _nodes.length ||
                _nodes[value.targetIndex].id != value.reference.id)
            {
                result.state = value.reference.id < 0
                    ? ReferenceResolutionState.unresolvedLocal
                    : ReferenceResolutionState.unresolvedPositive;
                result.targetIndex = 0;
                return result;
            }

            ref const node = _nodes[value.targetIndex];
            result.location = node.location;
            result.metadata = node.metadata;
            result.tags = node.tags;
        }

        return result;
    }

    void popFront() @safe pure nothrow @nogc
    in (!empty)
    {
        _resolved.popFront();
    }

    @property size_t length() const @safe pure nothrow @nogc
    {
        return _resolved.length;
    }
}

/** Borrowed complete projection of one Owned Way. */
struct OwnedCompleteWayView
{
    OsmId id;
    OwnedMetadata metadata;
    const(OwnedTag)[] tags;
    const(OwnedNodeRef)[] references;
    OwnedCompleteNodeRange nodes;

    @property bool isClosed() const @safe pure nothrow @nogc
    {
        return references.length >= 2 &&
               references[0].id == references[$ - 1].id;
    }
}

/** One Owned Relation member enriched with its read-only typed target view. */
struct OwnedCompleteRelationMember
{
    OwnedRelationMember member;
    ReferenceResolutionState state;
    size_t targetIndex;
    OwnedElementView target;

    @property bool resolved() const @safe pure nothrow @nogc
    {
        return state == ReferenceResolutionState.resolved;
    }
}

/** Lazy ordered complete member range for one Owned Relation. */
struct OwnedCompleteRelationMemberRange
{
private:
    const(OwnedNode)[] _nodes;
    const(OwnedWay)[] _ways;
    const(OwnedRelation)[] _relations;
    OwnedResolvedRelationMemberRange _resolved;

    this(
        const(OwnedNode)[] nodes,
        const(OwnedWay)[] ways,
        const(OwnedRelation)[] relations,
        OwnedResolvedRelationMemberRange resolved)
        @safe nothrow
    {
        _nodes = nodes;
        _ways = ways;
        _relations = relations;
        _resolved = resolved;
    }

public:
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _resolved.empty;
    }

    @property OwnedCompleteRelationMember front() @safe nothrow
    in (!empty)
    {
        auto value = _resolved.front;

        OwnedCompleteRelationMember result;
        result.member = value.member;
        result.state = value.state;
        result.targetIndex = value.targetIndex;

        if (!value.resolved)
            return result;

        bool validIndex;
        final switch (value.member.type)
        {
            case ElementType.node:
                validIndex =
                    value.targetIndex < _nodes.length &&
                    _nodes[value.targetIndex].id == value.member.id;
                break;
            case ElementType.way:
                validIndex =
                    value.targetIndex < _ways.length &&
                    _ways[value.targetIndex].id == value.member.id;
                break;
            case ElementType.relation:
                validIndex =
                    value.targetIndex < _relations.length &&
                    _relations[value.targetIndex].id == value.member.id;
                break;
        }

        if (!validIndex)
        {
            result.state = value.member.id < 0
                ? ReferenceResolutionState.unresolvedLocal
                : ReferenceResolutionState.unresolvedPositive;
            result.targetIndex = 0;
            return result;
        }

        result.target = OwnedElementView(
            value.member.type,
            value.targetIndex,
            _nodes,
            _ways,
            _relations);
        return result;
    }

    void popFront() @safe pure nothrow @nogc
    in (!empty)
    {
        _resolved.popFront();
    }

    @property size_t length() const @safe pure nothrow @nogc
    {
        return _resolved.length;
    }
}

/** Borrowed complete projection of one Owned Relation. */
struct OwnedCompleteRelationView
{
    OsmId id;
    OwnedMetadata metadata;
    const(OwnedTag)[] tags;
    const(OwnedRelationMember)[] sourceMembers;
    OwnedCompleteRelationMemberRange members;
}

/** Create a lazy complete Store Way projection. */
StoreCompleteWayView completeWay(
    OsmStore store,
    StoreWayView way)
    @safe nothrow @nogc
{
    StoreCompleteWayView result;
    result.source = way;
    result.nodes = StoreCompleteNodeRange(
        store,
        store.resolveNodes(way));
    return result;
}

/** Create a lazy complete Store Relation projection. */
StoreCompleteRelationView completeRelation(
    OsmStore store,
    StoreRelationView relation)
    @safe nothrow @nogc
{
    StoreCompleteRelationView result;
    result.source = relation;
    result.members = StoreCompleteRelationMemberRange(
        store,
        store.resolveMembers(relation));
    return result;
}

/** Create a lazy complete Owned Way projection. */
OwnedCompleteWayView completeWay(
    ref const OwnedDataset dataset,
    ref OwnedDatasetIndex index,
    ref const OwnedWay way)
    @safe nothrow
{
    OwnedCompleteWayView result;
    result.id = way.id;
    result.metadata = way.metadata;
    result.tags = way.tags;
    result.references = way.nodes;
    result.nodes = OwnedCompleteNodeRange(
        dataset.nodes,
        index.resolveNodes(way));
    return result;
}

/** Create a lazy complete Owned Relation projection. */
OwnedCompleteRelationView completeRelation(
    ref const OwnedDataset dataset,
    ref OwnedDatasetIndex index,
    ref const OwnedRelation relation)
    @safe nothrow
{
    OwnedCompleteRelationView result;
    result.id = relation.id;
    result.metadata = relation.metadata;
    result.tags = relation.tags;
    result.sourceMembers = relation.members;
    result.members = OwnedCompleteRelationMemberRange(
        dataset.nodes,
        dataset.ways,
        dataset.relations,
        index.resolveMembers(relation));
    return result;
}

/** Identity-based OSM closed-Way test. */
bool isClosedWay(StoreWayView way) @safe nothrow @nogc
{
    auto refs = way.nodes;
    if (refs.length < 2)
        return false;

    const firstId = refs.front.id;
    OsmId lastId = firstId;

    while (!refs.empty)
    {
        lastId = refs.front.id;
        refs.popFront();
    }

    return firstId == lastId;
}

/** Identity-based OSM closed-Way test. */
bool isClosedWay(ref const OwnedWay way)
    @safe pure nothrow @nogc
{
    return way.nodes.length >= 2 &&
           way.nodes[0].id == way.nodes[$ - 1].id;
}

/** Inspect direct completeness of one Store Way. */
CompleteObjectStatus completeStatus(StoreCompleteWayView way)
    @safe nothrow @nogc
{
    CompleteObjectStatus result;
    result.state = CompleteObjectState.complete;

    auto nodes = way.nodes;
    size_t childIndex;
    while (!nodes.empty)
    {
        const node = nodes.front;
        if (!node.resolved)
            recordIssue(
                result,
                node.state,
                childIndex,
                ElementType.node,
                node.reference.id);

        nodes.popFront();
        ++childIndex;
    }

    return result;
}

/** Inspect direct completeness of one Owned Way. */
CompleteObjectStatus completeStatus(OwnedCompleteWayView way)
    @safe nothrow
{
    CompleteObjectStatus result;
    result.state = CompleteObjectState.complete;

    auto nodes = way.nodes;
    size_t childIndex;
    while (!nodes.empty)
    {
        const node = nodes.front;
        if (!node.resolved)
            recordIssue(
                result,
                node.state,
                childIndex,
                ElementType.node,
                node.reference.id);

        nodes.popFront();
        ++childIndex;
    }

    return result;
}

/** Inspect direct completeness of one Store Relation. */
CompleteObjectStatus completeStatus(StoreCompleteRelationView relation)
    @safe nothrow @nogc
{
    CompleteObjectStatus result;
    result.state = CompleteObjectState.complete;

    auto members = relation.members;
    size_t childIndex;
    while (!members.empty)
    {
        const member = members.front;
        if (!member.resolved)
            recordIssue(
                result,
                member.state,
                childIndex,
                member.member.type,
                member.member.id);

        members.popFront();
        ++childIndex;
    }

    return result;
}

/** Inspect direct completeness of one Owned Relation. */
CompleteObjectStatus completeStatus(OwnedCompleteRelationView relation)
    @safe nothrow
{
    CompleteObjectStatus result;
    result.state = CompleteObjectState.complete;

    auto members = relation.members;
    size_t childIndex;
    while (!members.empty)
    {
        const member = members.front;
        if (!member.resolved)
            recordIssue(
                result,
                member.state,
                childIndex,
                member.member.type,
                member.member.id);

        members.popFront();
        ++childIndex;
    }

    return result;
}

/**
 * Compute exact OSM-native bounds from all resolved Store Way Nodes.
 *
 * Resolved locations contribute to bounds even when another reference is
 * partial or invalid. The returned status states whether every required
 * location was available.
 */
CompleteObjectStatus locationBounds(
    StoreCompleteWayView way,
    out LocationBounds bounds)
    @safe nothrow @nogc
{
    bounds = LocationBounds.init;
    CompleteObjectStatus result;
    result.state = CompleteObjectState.complete;

    auto nodes = way.nodes;
    size_t childIndex;
    while (!nodes.empty)
    {
        const node = nodes.front;
        if (node.resolved)
            bounds.include(node.location);
        else
            recordIssue(
                result,
                node.state,
                childIndex,
                ElementType.node,
                node.reference.id);

        nodes.popFront();
        ++childIndex;
    }

    return result;
}

/** Compute exact OSM-native bounds from all resolved Owned Way Nodes. */
CompleteObjectStatus locationBounds(
    OwnedCompleteWayView way,
    out LocationBounds bounds)
    @safe nothrow
{
    bounds = LocationBounds.init;
    CompleteObjectStatus result;
    result.state = CompleteObjectState.complete;

    auto nodes = way.nodes;
    size_t childIndex;
    while (!nodes.empty)
    {
        const node = nodes.front;
        if (node.resolved)
            bounds.include(node.location);
        else
            recordIssue(
                result,
                node.state,
                childIndex,
                ElementType.node,
                node.reference.id);

        nodes.popFront();
        ++childIndex;
    }

    return result;
}

private:

void recordIssue(
    ref CompleteObjectStatus status,
    ReferenceResolutionState issue,
    size_t childIndex,
    ElementType type,
    OsmId id)
    @safe pure nothrow @nogc
{
    const nextState =
        issue == ReferenceResolutionState.unresolvedPositive
        ? CompleteObjectState.partial
        : CompleteObjectState.invalid;

    const escalates =
        status.state == CompleteObjectState.partial &&
        nextState == CompleteObjectState.invalid;

    if (status.state == CompleteObjectState.complete || escalates)
        status.state = nextState;

    if (!status.hasIssue || escalates)
    {
        status.issue = issue;
        status.childIndex = childIndex;
        status.referenceType = type;
        status.referenceId = id;
        status.hasIssue = true;
    }
}

unittest
{
    auto store = new OsmStore();
    StoreStatus status;

    OwnedNode a;
    a.id = 1;
    a.location = LocationView(10, 20);
    OsmHandle aHandle;
    assert(store.add(a, aHandle, status));

    OwnedNode b;
    b.id = 2;
    b.location = LocationView(30, 5);
    OsmHandle bHandle;
    assert(store.add(b, bHandle, status));

    OwnedWay way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(1);
    way.nodes ~= OwnedNodeRef(2);
    way.nodes ~= OwnedNodeRef(1);

    OsmHandle wayHandle;
    assert(store.add(way, wayHandle, status));

    StoreWayView wayView;
    assert(store.way(wayHandle, wayView, status));

    auto complete = completeWay(store, wayView);
    assert(complete.isClosed);

    auto nodes = complete.nodes;
    assert(nodes.length == 3);
    assert(nodes.front.resolved);
    assert(nodes.front.node.id == 1);
    assert(nodes.front.location == LocationView(10, 20));

    assert(completeStatus(complete).complete);

    LocationBounds bounds;
    auto boundsStatus = locationBounds(complete, bounds);
    assert(boundsStatus.complete);
    assert(!bounds.empty);
    assert(bounds.minLatitudeNanodegrees == 10);
    assert(bounds.maxLatitudeNanodegrees == 30);
    assert(bounds.minLongitudeNanodegrees == 5);
    assert(bounds.maxLongitudeNanodegrees == 20);
}

unittest
{
    auto store = new OsmStore();
    StoreStatus status;

    OwnedNode node;
    node.id = 1;
    node.location = LocationView(10, 20);
    OsmHandle nodeHandle;
    assert(store.add(node, nodeHandle, status));

    OwnedWay partial;
    partial.id = 11;
    partial.nodes ~= OwnedNodeRef(1);
    partial.nodes ~= OwnedNodeRef(999);

    OsmHandle wayHandle;
    assert(store.add(partial, wayHandle, status));

    StoreWayView wayView;
    assert(store.way(wayHandle, wayView, status));

    auto complete = completeWay(store, wayView);
    auto objectStatus = completeStatus(complete);
    assert(objectStatus.state == CompleteObjectState.partial);
    assert(objectStatus.issue ==
        ReferenceResolutionState.unresolvedPositive);
    assert(objectStatus.childIndex == 1);

    LocationBounds bounds;
    auto boundsStatus = locationBounds(complete, bounds);
    assert(boundsStatus.state == CompleteObjectState.partial);
    assert(bounds.minLatitudeNanodegrees == 10);
    assert(bounds.maxLongitudeNanodegrees == 20);
}

unittest
{
    OwnedDataset dataset;

    OwnedNode node;
    node.id = 1;
    node.location = LocationView(100, 200);
    dataset.nodes ~= node;

    OwnedWay way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(1);
    way.nodes ~= OwnedNodeRef(1);
    dataset.ways ~= way;

    OwnedRelation relation;
    relation.id = 20;
    relation.members ~= OwnedRelationMember(
        ElementType.node,
        1,
        null);
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        null);
    dataset.relations ~= relation;

    import osm.validate : DatasetValidationIssue;
    DatasetValidationIssue issue;
    OwnedDatasetIndex index;
    assert(index.build(dataset, issue));

    auto completeWayView =
        completeWay(dataset, index, dataset.ways[0]);
    assert(completeWayView.isClosed);
    assert(completeStatus(completeWayView).complete);

    auto completeRelationView =
        completeRelation(dataset, index, dataset.relations[0]);
    auto members = completeRelationView.members;

    assert(members.front.resolved);
    assert(members.front.target.type == ElementType.node);
    assert(members.front.target.node.id == 1);
    members.popFront();

    assert(members.front.resolved);
    assert(members.front.target.type == ElementType.way);
    assert(members.front.target.way.id == 10);
    assert(completeStatus(completeRelationView).complete);
}

unittest
{
    auto store = new OsmStore();
    StoreStatus status;

    OwnedNode node;
    node.id = 1;
    OsmHandle nodeHandle;
    assert(store.add(node, nodeHandle, status));

    OwnedWay way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(1);
    OsmHandle wayHandle;
    assert(store.add(way, wayHandle, status));

    OwnedRelation relation;
    relation.id = 20;
    relation.members ~= OwnedRelationMember(
        ElementType.node,
        1,
        null);
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        null);
    OsmHandle relationHandle;
    assert(store.add(relation, relationHandle, status));

    StoreRelationView relationView;
    assert(store.relation(relationHandle, relationView, status));

    auto complete = completeRelation(store, relationView);
    auto members = complete.members;

    assert(members.front.resolved);
    assert(members.front.node.id == 1);
    members.popFront();

    assert(members.front.resolved);
    assert(members.front.way.id == 10);
    assert(completeStatus(complete).complete);
}
