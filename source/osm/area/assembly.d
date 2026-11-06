/**
 * OSM-specific closed-Way and multipolygon ring assembly.
 *
 * The assembler joins Way members by exact OSM Node identity. It preserves
 * outer/inner roles and source provenance, may reverse a Way's traversal
 * direction without mutating source data, and reports incomplete, ambiguous,
 * or invalid graph structure explicitly.
 *
 * This module does not perform generic polygon validity, intersection,
 * containment, orientation, projection, or metric operations.
 */
module osm.area.assembly;

import osm.complete :
    OwnedCompleteWayView,
    StoreCompleteWayView,
    completeRelation,
    completeWay;
import osm.model.owned :
    OwnedDataset,
    OwnedRelation,
    OwnedRelationMember,
    OwnedWay;
import osm.store :
    OsmStore,
    StoreRelationView,
    StoreWayView;
import osm.topology :
    OwnedDatasetIndex,
    ReferenceResolutionState;
import osm.view.element :
    ElementType,
    OsmId;
import osm.view.location :
    LocationView;
import osm.view.tag :
    tagEquals;

/** Semantic role assigned to one assembled multipolygon ring. */
enum AreaRingRole : ubyte
{
    none,
    outer,
    inner,
}

/** Aggregate outcome of one area assembly operation. */
enum AreaAssemblyState : ubyte
{
    notAssembled,
    complete,
    partial,
    ambiguous,
    invalid,
}

/** Specific assembly condition recorded in AreaAssemblyResult. */
enum AreaAssemblyIssueKind : ubyte
{
    none,
    notMultipolygon,
    missingOuterRing,
    invalidMemberRole,
    unsupportedMemberType,
    duplicateMember,
    unresolvedWayMember,
    wayTooShort,
    unresolvedNode,
    incompleteChain,
    unclosedChain,
    ambiguousJunction,
}

/**
 * One resolved or unresolved OSM Node occurrence in an assembled path.
 *
 * location is meaningful only when resolved is true.
 */
struct AreaVertex
{
    OsmId nodeId;
    ReferenceResolutionState state;
    LocationView location;

    @property bool resolved() const @safe pure nothrow @nogc
    {
        return state == ReferenceResolutionState.resolved;
    }
}

/**
 * Provenance for one source Way contribution to an assembled path.
 *
 * firstVertex is the index of the source Way's first vertex in the assembled
 * traversal direction. For a continuation segment this is the shared endpoint
 * already present in the path. vertexCount is the source Way Node count.
 */
struct AreaRingSegment
{
    OsmId wayId;

    bool hasMemberIndex;
    size_t memberIndex;

    bool reversed;

    size_t firstVertex;
    size_t vertexCount;
}

/** One successfully closed OSM ring assembled by Node identity. */
struct AreaRing
{
    AreaRingRole role;
    AreaVertex[] vertices;
    AreaRingSegment[] segments;

    bool locationsComplete;

    @property bool closed() const @safe pure nothrow @nogc
    {
        return vertices.length >= 2 &&
               vertices[0].nodeId == vertices[$ - 1].nodeId;
    }
}

/**
 * One non-closed or ambiguity-stopped chain retained for diagnostics.
 *
 * The chain keeps the same source provenance as a successful ring.
 */
struct AreaOpenChain
{
    AreaRingRole role;
    AreaVertex[] vertices;
    AreaRingSegment[] segments;

    bool locationsComplete;
}

/** One explicit issue encountered while assembling an OSM area. */
struct AreaAssemblyIssue
{
    AreaAssemblyIssueKind kind;

    AreaRingRole role;

    size_t memberIndex;
    bool hasMemberIndex;

    ElementType memberType;
    OsmId memberId;

    OsmId nodeId;

    size_t childIndex;
    bool hasChildIndex;

    size_t candidateCount;

    ReferenceResolutionState resolution;
}

/**
 * Owning result of OSM-specific area/ring assembly.
 *
 * rings and openChains own their path arrays. They remain valid after source
 * view invalidation. Exact LocationView coordinates are copied as nanodegree
 * values; no floating-point conversion is performed.
 */
struct AreaAssemblyResult
{
    AreaAssemblyState state = AreaAssemblyState.notAssembled;

    ElementType sourceType;
    OsmId sourceId;

    AreaRing[] rings;
    AreaOpenChain[] openChains;
    AreaAssemblyIssue[] issues;

    @property bool complete() const @safe pure nothrow @nogc
    {
        return state == AreaAssemblyState.complete;
    }

    @property size_t outerRingCount() const @safe pure nothrow @nogc
    {
        size_t count;
        foreach (ref const ring; rings)
            if (ring.role == AreaRingRole.outer)
                ++count;
        return count;
    }

    @property size_t innerRingCount() const @safe pure nothrow @nogc
    {
        size_t count;
        foreach (ref const ring; rings)
            if (ring.role == AreaRingRole.inner)
                ++count;
        return count;
    }
}

private struct WayPiece
{
    AreaRingRole role;
    OsmId wayId;

    bool hasMemberIndex;
    size_t memberIndex;

    AreaVertex[] vertices;

    @property bool closed() const @safe pure nothrow @nogc
    {
        return vertices.length >= 2 &&
               vertices[0].nodeId == vertices[$ - 1].nodeId;
    }

    @property OsmId firstNodeId() const @safe pure nothrow @nogc
    in (vertices.length > 0)
    {
        return vertices[0].nodeId;
    }

    @property OsmId lastNodeId() const @safe pure nothrow @nogc
    in (vertices.length > 0)
    {
        return vertices[$ - 1].nodeId;
    }

    @property bool locationsComplete() const @safe pure nothrow @nogc
    {
        foreach (ref const vertex; vertices)
            if (!vertex.resolved)
                return false;
        return true;
    }
}

private struct MemberKey
{
    OsmId wayId;
    AreaRingRole role;
}

/**
 * Assemble one closed Store Way as an outer OSM ring.
 *
 * This operation is structural. It assumes the caller has already decided that
 * the Way is intended to represent an area; it does not infer area semantics
 * from arbitrary tagging.
 */
AreaAssemblyResult assembleClosedWayArea(
    OsmStore store,
    StoreWayView way)
    @safe
{
    AreaAssemblyResult result;
    result.state = AreaAssemblyState.complete;
    result.sourceType = ElementType.way;
    result.sourceId = way.id;

    WayPiece piece = collectStoreWay(
        store,
        way,
        AreaRingRole.outer,
        false,
        0,
        result);

    finishSingleClosedWay(piece, result);
    return result;
}

/** Assemble one closed Owned Way as an outer OSM ring. */
AreaAssemblyResult assembleClosedWayArea(
    ref const OwnedDataset dataset,
    ref OwnedDatasetIndex index,
    ref const OwnedWay way)
    @safe
{
    AreaAssemblyResult result;
    result.state = AreaAssemblyState.complete;
    result.sourceType = ElementType.way;
    result.sourceId = way.id;

    WayPiece piece = collectOwnedWay(
        dataset,
        index,
        way,
        AreaRingRole.outer,
        false,
        0,
        result);

    finishSingleClosedWay(piece, result);
    return result;
}

/**
 * Assemble a Store multipolygon Relation into OSM outer/inner rings.
 *
 * Relation members must be Ways with exact role bytes "outer" or "inner".
 * Member order is not required to follow ring order. Way direction is ignored
 * for connectivity and may be reversed in the result without mutating source.
 *
 * Node/Relation members and empty/unknown roles are reported explicitly; this
 * function does not guess legacy roles or recursively reinterpret nested
 * Relations as multipolygon members.
 */
AreaAssemblyResult assembleMultipolygon(
    OsmStore store,
    StoreRelationView relation)
    @safe
{
    AreaAssemblyResult result;
    result.state = AreaAssemblyState.complete;
    result.sourceType = ElementType.relation;
    result.sourceId = relation.id;

    if (!tagEquals(relation.tags, "type", "multipolygon"))
    {
        addIssue(
            result,
            AreaAssemblyIssueKind.notMultipolygon,
            AreaRingRole.none,
            false,
            0,
            ElementType.relation,
            relation.id,
            0,
            0,
            ReferenceResolutionState.none,
            AreaAssemblyState.invalid);
        return result;
    }

    WayPiece[] pieces;
    bool[MemberKey] seen;
    bool missingOuter;
    bool missingInner;

    auto complete = completeRelation(store, relation);
    auto members = complete.members;
    size_t memberIndex;

    while (!members.empty)
    {
        auto member = members.front;
        members.popFront();

        const role = parseRole(member.member.role);

        if (role == AreaRingRole.none)
        {
            addIssue(
                result,
                AreaAssemblyIssueKind.invalidMemberRole,
                role,
                true,
                memberIndex,
                member.member.type,
                member.member.id,
                0,
                0,
                member.state,
                AreaAssemblyState.invalid);
            ++memberIndex;
            continue;
        }

        if (member.member.type != ElementType.way)
        {
            addIssue(
                result,
                AreaAssemblyIssueKind.unsupportedMemberType,
                role,
                true,
                memberIndex,
                member.member.type,
                member.member.id,
                0,
                0,
                member.state,
                AreaAssemblyState.invalid);
            ++memberIndex;
            continue;
        }

        if (!member.resolved)
        {
            noteMissingRole(role, missingOuter, missingInner);
            addUnresolvedWayIssue(
                result,
                role,
                memberIndex,
                member.member.id,
                member.state);
            ++memberIndex;
            continue;
        }

        const key = MemberKey(member.member.id, role);
        if (key in seen)
        {
            addIssue(
                result,
                AreaAssemblyIssueKind.duplicateMember,
                role,
                true,
                memberIndex,
                ElementType.way,
                member.member.id,
                0,
                0,
                member.state,
                AreaAssemblyState.invalid);
            ++memberIndex;
            continue;
        }
        seen[key] = true;

        WayPiece piece = collectStoreWay(
            store,
            member.way,
            role,
            true,
            memberIndex,
            result);

        if (piece.vertices.length >= 2)
            pieces ~= piece;

        ++memberIndex;
    }

    assembleRole(
        AreaRingRole.outer,
        pieces,
        missingOuter,
        result);
    assembleRole(
        AreaRingRole.inner,
        pieces,
        missingInner,
        result);

    finalizeMultipolygon(result, missingOuter);
    return result;
}

/** Assemble an indexed Owned multipolygon Relation into outer/inner rings. */
AreaAssemblyResult assembleMultipolygon(
    ref const OwnedDataset dataset,
    ref OwnedDatasetIndex index,
    ref const OwnedRelation relation)
    @safe
{
    AreaAssemblyResult result;
    result.state = AreaAssemblyState.complete;
    result.sourceType = ElementType.relation;
    result.sourceId = relation.id;

    if (!ownedTagEquals(relation, "type", "multipolygon"))
    {
        addIssue(
            result,
            AreaAssemblyIssueKind.notMultipolygon,
            AreaRingRole.none,
            false,
            0,
            ElementType.relation,
            relation.id,
            0,
            0,
            ReferenceResolutionState.none,
            AreaAssemblyState.invalid);
        return result;
    }

    WayPiece[] pieces;
    bool[MemberKey] seen;
    bool missingOuter;
    bool missingInner;

    auto complete = completeRelation(dataset, index, relation);
    auto members = complete.members;
    size_t memberIndex;

    while (!members.empty)
    {
        auto member = members.front;
        members.popFront();

        const role = parseRole(member.member.role);

        if (role == AreaRingRole.none)
        {
            addIssue(
                result,
                AreaAssemblyIssueKind.invalidMemberRole,
                role,
                true,
                memberIndex,
                member.member.type,
                member.member.id,
                0,
                0,
                member.state,
                AreaAssemblyState.invalid);
            ++memberIndex;
            continue;
        }

        if (member.member.type != ElementType.way)
        {
            addIssue(
                result,
                AreaAssemblyIssueKind.unsupportedMemberType,
                role,
                true,
                memberIndex,
                member.member.type,
                member.member.id,
                0,
                0,
                member.state,
                AreaAssemblyState.invalid);
            ++memberIndex;
            continue;
        }

        if (!member.resolved)
        {
            noteMissingRole(role, missingOuter, missingInner);
            addUnresolvedWayIssue(
                result,
                role,
                memberIndex,
                member.member.id,
                member.state);
            ++memberIndex;
            continue;
        }

        const key = MemberKey(member.member.id, role);
        if (key in seen)
        {
            addIssue(
                result,
                AreaAssemblyIssueKind.duplicateMember,
                role,
                true,
                memberIndex,
                ElementType.way,
                member.member.id,
                0,
                0,
                member.state,
                AreaAssemblyState.invalid);
            ++memberIndex;
            continue;
        }
        seen[key] = true;

        ref const way = member.target.way;
        WayPiece piece = collectOwnedWay(
            dataset,
            index,
            way,
            role,
            true,
            memberIndex,
            result);

        if (piece.vertices.length >= 2)
            pieces ~= piece;

        ++memberIndex;
    }

    assembleRole(
        AreaRingRole.outer,
        pieces,
        missingOuter,
        result);
    assembleRole(
        AreaRingRole.inner,
        pieces,
        missingInner,
        result);

    finalizeMultipolygon(result, missingOuter);
    return result;
}

private:

void finishSingleClosedWay(
    ref WayPiece piece,
    ref AreaAssemblyResult result)
    @safe
{
    if (piece.vertices.length < 2)
        return;

    if (!piece.closed)
    {
        AreaOpenChain chain = pathFromPiece(piece);
        result.openChains ~= chain;

        addIssue(
            result,
            AreaAssemblyIssueKind.unclosedChain,
            AreaRingRole.outer,
            false,
            0,
            ElementType.way,
            piece.wayId,
            piece.lastNodeId,
            0,
            ReferenceResolutionState.none,
            AreaAssemblyState.invalid);
        return;
    }

    result.rings ~= ringFromPiece(piece);
}

WayPiece collectStoreWay(
    OsmStore store,
    StoreWayView way,
    AreaRingRole role,
    bool hasMemberIndex,
    size_t memberIndex,
    ref AreaAssemblyResult result)
    @safe
{
    WayPiece piece;
    piece.role = role;
    piece.wayId = way.id;
    piece.hasMemberIndex = hasMemberIndex;
    piece.memberIndex = memberIndex;

    auto complete = completeWay(store, way);
    auto nodes = complete.nodes;
    size_t childIndex;

    while (!nodes.empty)
    {
        auto node = nodes.front;
        nodes.popFront();

        AreaVertex vertex;
        vertex.nodeId = node.reference.id;
        vertex.state = node.state;
        if (node.resolved)
            vertex.location = node.location;
        else
            addNodeIssue(
                result,
                role,
                hasMemberIndex,
                memberIndex,
                way.id,
                childIndex,
                node.reference.id,
                node.state);

        piece.vertices ~= vertex;
        ++childIndex;
    }

    if (piece.vertices.length < 2)
    {
        addIssue(
            result,
            AreaAssemblyIssueKind.wayTooShort,
            role,
            hasMemberIndex,
            memberIndex,
            ElementType.way,
            way.id,
            0,
            0,
            ReferenceResolutionState.none,
            AreaAssemblyState.invalid);
    }

    return piece;
}

WayPiece collectOwnedWay(
    ref const OwnedDataset dataset,
    ref OwnedDatasetIndex index,
    ref const OwnedWay way,
    AreaRingRole role,
    bool hasMemberIndex,
    size_t memberIndex,
    ref AreaAssemblyResult result)
    @safe
{
    WayPiece piece;
    piece.role = role;
    piece.wayId = way.id;
    piece.hasMemberIndex = hasMemberIndex;
    piece.memberIndex = memberIndex;

    auto complete = completeWay(dataset, index, way);
    auto nodes = complete.nodes;
    size_t childIndex;

    while (!nodes.empty)
    {
        auto node = nodes.front;
        nodes.popFront();

        AreaVertex vertex;
        vertex.nodeId = node.reference.id;
        vertex.state = node.state;
        if (node.resolved)
            vertex.location = node.location;
        else
            addNodeIssue(
                result,
                role,
                hasMemberIndex,
                memberIndex,
                way.id,
                childIndex,
                node.reference.id,
                node.state);

        piece.vertices ~= vertex;
        ++childIndex;
    }

    if (piece.vertices.length < 2)
    {
        addIssue(
            result,
            AreaAssemblyIssueKind.wayTooShort,
            role,
            hasMemberIndex,
            memberIndex,
            ElementType.way,
            way.id,
            0,
            0,
            ReferenceResolutionState.none,
            AreaAssemblyState.invalid);
    }

    return piece;
}

void assembleRole(
    AreaRingRole role,
    ref WayPiece[] pieces,
    bool roleHasMissingWay,
    ref AreaAssemblyResult result)
    @safe
{
    bool[] used;
    used.length = pieces.length;

    foreach (startIndex, ref piece; pieces)
    {
        if (piece.role != role || used[startIndex])
            continue;

        used[startIndex] = true;

        if (piece.closed)
        {
            result.rings ~= ringFromPiece(piece);
            continue;
        }

        AreaOpenChain chain = pathFromPiece(piece);
        OsmId firstNode = chain.vertices[0].nodeId;
        OsmId currentNode = chain.vertices[$ - 1].nodeId;

        bool failed;
        while (currentNode != firstNode)
        {
            size_t candidateIndex = size_t.max;
            size_t candidateCount;

            foreach (i, ref candidate; pieces)
            {
                if (used[i] ||
                    candidate.role != role ||
                    candidate.closed ||
                    candidate.vertices.length < 2)
                    continue;

                if (candidate.firstNodeId == currentNode ||
                    candidate.lastNodeId == currentNode)
                {
                    candidateIndex = i;
                    ++candidateCount;
                }
            }

            if (candidateCount == 0)
            {
                result.openChains ~= chain;

                addIssue(
                    result,
                    roleHasMissingWay
                        ? AreaAssemblyIssueKind.incompleteChain
                        : AreaAssemblyIssueKind.unclosedChain,
                    role,
                    piece.hasMemberIndex,
                    piece.memberIndex,
                    ElementType.way,
                    piece.wayId,
                    currentNode,
                    0,
                    ReferenceResolutionState.none,
                    roleHasMissingWay
                        ? AreaAssemblyState.partial
                        : AreaAssemblyState.invalid);
                failed = true;
                break;
            }

            if (candidateCount > 1)
            {
                result.openChains ~= chain;

                addIssue(
                    result,
                    AreaAssemblyIssueKind.ambiguousJunction,
                    role,
                    piece.hasMemberIndex,
                    piece.memberIndex,
                    ElementType.way,
                    piece.wayId,
                    currentNode,
                    candidateCount,
                    ReferenceResolutionState.none,
                    AreaAssemblyState.ambiguous);
                return;
            }

            ref candidate = pieces[candidateIndex];
            const reversed =
                candidate.lastNodeId == currentNode;

            used[candidateIndex] = true;
            appendPiece(chain, candidate, reversed);
            currentNode = chain.vertices[$ - 1].nodeId;
        }

        if (failed)
            continue;

        AreaRing ring;
        ring.role = role;
        ring.vertices = chain.vertices;
        ring.segments = chain.segments;
        ring.locationsComplete = chain.locationsComplete;
        result.rings ~= ring;
    }
}

AreaRing ringFromPiece(ref const WayPiece piece)
    @safe
{
    AreaRing ring;
    ring.role = piece.role;
    ring.locationsComplete = piece.locationsComplete;

    appendVertices(ring.vertices, piece, false, false);

    AreaRingSegment segment;
    segment.wayId = piece.wayId;
    segment.hasMemberIndex = piece.hasMemberIndex;
    segment.memberIndex = piece.memberIndex;
    segment.reversed = false;
    segment.firstVertex = 0;
    segment.vertexCount = piece.vertices.length;
    ring.segments ~= segment;

    return ring;
}

AreaOpenChain pathFromPiece(ref const WayPiece piece)
    @safe
{
    AreaOpenChain chain;
    chain.role = piece.role;
    chain.locationsComplete = piece.locationsComplete;

    appendVertices(chain.vertices, piece, false, false);

    AreaRingSegment segment;
    segment.wayId = piece.wayId;
    segment.hasMemberIndex = piece.hasMemberIndex;
    segment.memberIndex = piece.memberIndex;
    segment.reversed = false;
    segment.firstVertex = 0;
    segment.vertexCount = piece.vertices.length;
    chain.segments ~= segment;

    return chain;
}

void appendPiece(
    ref AreaOpenChain chain,
    ref const WayPiece piece,
    bool reversed)
    @safe
{
    assert(chain.vertices.length > 0);
    assert(piece.vertices.length >= 2);

    AreaRingSegment segment;
    segment.wayId = piece.wayId;
    segment.hasMemberIndex = piece.hasMemberIndex;
    segment.memberIndex = piece.memberIndex;
    segment.reversed = reversed;
    segment.firstVertex = chain.vertices.length - 1;
    segment.vertexCount = piece.vertices.length;
    chain.segments ~= segment;

    appendVertices(
        chain.vertices,
        piece,
        reversed,
        true);

    if (!piece.locationsComplete)
        chain.locationsComplete = false;
}

void appendVertices(
    ref AreaVertex[] destination,
    ref const WayPiece piece,
    bool reversed,
    bool skipFirst)
    @safe
{
    if (!reversed)
    {
        size_t begin = skipFirst ? 1 : 0;
        foreach (i; begin .. piece.vertices.length)
            destination ~= piece.vertices[i];
        return;
    }

    if (piece.vertices.length == 0)
        return;

    size_t count = piece.vertices.length;
    size_t first = skipFirst ? 1 : 0;
    foreach (offset; first .. count)
    {
        const i = count - 1 - offset;
        destination ~= piece.vertices[i];
    }
}

void finalizeMultipolygon(
    ref AreaAssemblyResult result,
    bool missingOuter)
    @safe
{
    if (result.outerRingCount != 0)
        return;

    addIssue(
        result,
        AreaAssemblyIssueKind.missingOuterRing,
        AreaRingRole.outer,
        false,
        0,
        ElementType.relation,
        result.sourceId,
        0,
        0,
        ReferenceResolutionState.none,
        missingOuter
            ? AreaAssemblyState.partial
            : AreaAssemblyState.invalid);
}

void addUnresolvedWayIssue(
    ref AreaAssemblyResult result,
    AreaRingRole role,
    size_t memberIndex,
    OsmId wayId,
    ReferenceResolutionState resolution)
    @safe
{
    const state =
        resolution == ReferenceResolutionState.unresolvedPositive
        ? AreaAssemblyState.partial
        : AreaAssemblyState.invalid;

    addIssue(
        result,
        AreaAssemblyIssueKind.unresolvedWayMember,
        role,
        true,
        memberIndex,
        ElementType.way,
        wayId,
        0,
        0,
        resolution,
        state);
}

void addNodeIssue(
    ref AreaAssemblyResult result,
    AreaRingRole role,
    bool hasMemberIndex,
    size_t memberIndex,
    OsmId wayId,
    size_t childIndex,
    OsmId nodeId,
    ReferenceResolutionState resolution)
    @safe
{
    const state =
        resolution == ReferenceResolutionState.unresolvedPositive
        ? AreaAssemblyState.partial
        : AreaAssemblyState.invalid;

    AreaAssemblyIssue issue;
    issue.kind = AreaAssemblyIssueKind.unresolvedNode;
    issue.role = role;
    issue.hasMemberIndex = hasMemberIndex;
    issue.memberIndex = memberIndex;
    issue.memberType = ElementType.way;
    issue.memberId = wayId;
    issue.nodeId = nodeId;
    issue.childIndex = childIndex;
    issue.hasChildIndex = true;
    issue.resolution = resolution;

    result.issues ~= issue;
    promote(result, state);
}

void addIssue(
    ref AreaAssemblyResult result,
    AreaAssemblyIssueKind kind,
    AreaRingRole role,
    bool hasMemberIndex,
    size_t memberIndex,
    ElementType memberType,
    OsmId memberId,
    OsmId nodeId,
    size_t candidateCount,
    ReferenceResolutionState resolution,
    AreaAssemblyState state)
    @safe
{
    AreaAssemblyIssue issue;
    issue.kind = kind;
    issue.role = role;
    issue.hasMemberIndex = hasMemberIndex;
    issue.memberIndex = memberIndex;
    issue.memberType = memberType;
    issue.memberId = memberId;
    issue.nodeId = nodeId;
    issue.candidateCount = candidateCount;
    issue.resolution = resolution;

    result.issues ~= issue;
    promote(result, state);
}

void promote(
    ref AreaAssemblyResult result,
    AreaAssemblyState state)
    @safe pure nothrow @nogc
{
    if (severity(state) > severity(result.state))
        result.state = state;
}

int severity(AreaAssemblyState state)
    @safe pure nothrow @nogc
{
    final switch (state)
    {
        case AreaAssemblyState.notAssembled:
            return 0;
        case AreaAssemblyState.complete:
            return 1;
        case AreaAssemblyState.partial:
            return 2;
        case AreaAssemblyState.ambiguous:
            return 3;
        case AreaAssemblyState.invalid:
            return 4;
    }
}

void noteMissingRole(
    AreaRingRole role,
    ref bool missingOuter,
    ref bool missingInner)
    @safe pure nothrow @nogc
{
    if (role == AreaRingRole.outer)
        missingOuter = true;
    else if (role == AreaRingRole.inner)
        missingInner = true;
}

AreaRingRole parseRole(scope const(ubyte)[] role)
    @safe pure nothrow @nogc
{
    if (sameBytes(role, "outer"))
        return AreaRingRole.outer;
    if (sameBytes(role, "inner"))
        return AreaRingRole.inner;
    return AreaRingRole.none;
}

bool ownedTagEquals(
    ref const OwnedRelation relation,
    scope const(char)[] key,
    scope const(char)[] value)
    @safe pure nothrow @nogc
{
    foreach (ref const tag; relation.tags)
    {
        if (sameBytes(tag.key, key) &&
            sameBytes(tag.value, value))
            return true;
    }
    return false;
}

bool sameBytes(
    scope const(ubyte)[] stored,
    scope const(char)[] expected)
    @safe pure nothrow @nogc
{
    if (stored.length != expected.length)
        return false;

    foreach (i; 0 .. stored.length)
        if (stored[i] != cast(ubyte)expected[i])
            return false;

    return true;
}

unittest
{
    import osm.model.owned :
        OwnedNode,
        OwnedNodeRef;
    import osm.store :
        OsmHandle,
        StoreStatus;

    auto store = new OsmStore();
    StoreStatus status;

    const ids = [1L, 2L, 3L];
    const lats = [10L, 20L, 30L];
    const lons = [100L, 200L, 300L];

    foreach (i; 0 .. ids.length)
    {
        OwnedNode node;
        node.id = ids[i];
        node.location = LocationView(lats[i], lons[i]);
        OsmHandle handle;
        assert(store.add(node, handle, status));
    }

    OwnedWay way;
    way.id = 10;
    way.nodes ~= OwnedNodeRef(1);
    way.nodes ~= OwnedNodeRef(2);
    way.nodes ~= OwnedNodeRef(3);
    way.nodes ~= OwnedNodeRef(1);

    OsmHandle wayHandle;
    assert(store.add(way, wayHandle, status));

    StoreWayView view;
    assert(store.way(wayHandle, view, status));

    auto area = assembleClosedWayArea(store, view);
    assert(area.complete);
    assert(area.rings.length == 1);
    assert(area.rings[0].role == AreaRingRole.outer);
    assert(area.rings[0].closed);
    assert(area.rings[0].vertices.length == 4);
    assert(area.rings[0].locationsComplete);
    assert(area.rings[0].segments.length == 1);
    assert(!area.rings[0].segments[0].hasMemberIndex);
}

unittest
{
    import osm.model.owned :
        OwnedNode,
        OwnedNodeRef,
        OwnedTag;
    import osm.store :
        OsmHandle,
        StoreStatus;

    auto store = new OsmStore();
    StoreStatus status;

    foreach (id; 1L .. 7L)
    {
        OwnedNode node;
        node.id = id;
        node.location = LocationView(id, id * 10);
        OsmHandle handle;
        assert(store.add(node, handle, status));
    }

    OwnedWay a;
    a.id = 10;
    a.nodes ~= OwnedNodeRef(1);
    a.nodes ~= OwnedNodeRef(2);
    a.nodes ~= OwnedNodeRef(3);

    OwnedWay b;
    b.id = 11;
    b.nodes ~= OwnedNodeRef(1);
    b.nodes ~= OwnedNodeRef(4);
    b.nodes ~= OwnedNodeRef(3);

    OwnedWay inner;
    inner.id = 12;
    inner.nodes ~= OwnedNodeRef(5);
    inner.nodes ~= OwnedNodeRef(6);
    inner.nodes ~= OwnedNodeRef(5);

    OsmHandle aHandle;
    OsmHandle bHandle;
    OsmHandle innerHandle;
    assert(store.add(a, aHandle, status));
    assert(store.add(b, bHandle, status));
    assert(store.add(inner, innerHandle, status));

    OwnedRelation relation;
    relation.id = 20;
    relation.tags ~= OwnedTag(
        cast(immutable(ubyte)[])"type",
        cast(immutable(ubyte)[])"multipolygon");
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        cast(immutable(ubyte)[])"outer");
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        11,
        cast(immutable(ubyte)[])"outer");
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        12,
        cast(immutable(ubyte)[])"inner");

    OsmHandle relationHandle;
    assert(store.add(relation, relationHandle, status));

    StoreRelationView view;
    assert(store.relation(relationHandle, view, status));

    auto area = assembleMultipolygon(store, view);
    assert(area.complete);
    assert(area.outerRingCount == 1);
    assert(area.innerRingCount == 1);

    ref outer = area.rings[0];
    assert(outer.role == AreaRingRole.outer);
    assert(outer.closed);
    assert(outer.segments.length == 2);
    assert(!outer.segments[0].reversed);
    assert(outer.segments[1].reversed);
    assert(outer.vertices[0].nodeId == 1);
    assert(outer.vertices[$ - 1].nodeId == 1);
}

unittest
{
    import osm.model.owned :
        OwnedNode,
        OwnedNodeRef,
        OwnedTag;

    OwnedDataset dataset;

    foreach (id; 1L .. 10L)
    {
        OwnedNode node;
        node.id = id;
        node.location = LocationView(id, id);
        dataset.nodes ~= node;
    }

    OwnedWay outerA;
    outerA.id = 10;
    outerA.nodes ~= OwnedNodeRef(1);
    outerA.nodes ~= OwnedNodeRef(2);
    outerA.nodes ~= OwnedNodeRef(1);
    dataset.ways ~= outerA;

    OwnedWay outerB;
    outerB.id = 11;
    outerB.nodes ~= OwnedNodeRef(3);
    outerB.nodes ~= OwnedNodeRef(4);
    outerB.nodes ~= OwnedNodeRef(3);
    dataset.ways ~= outerB;

    OwnedWay inner;
    inner.id = 12;
    inner.nodes ~= OwnedNodeRef(5);
    inner.nodes ~= OwnedNodeRef(6);
    inner.nodes ~= OwnedNodeRef(5);
    dataset.ways ~= inner;

    OwnedRelation relation;
    relation.id = 20;
    relation.tags ~= OwnedTag(
        cast(immutable(ubyte)[])"type",
        cast(immutable(ubyte)[])"multipolygon");
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        11,
        cast(immutable(ubyte)[])"outer");
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        12,
        cast(immutable(ubyte)[])"inner");
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        cast(immutable(ubyte)[])"outer");
    dataset.relations ~= relation;

    import osm.validate : DatasetValidationIssue;
    DatasetValidationIssue issue;
    OwnedDatasetIndex index;
    assert(index.build(dataset, issue));

    auto area = assembleMultipolygon(
        dataset,
        index,
        dataset.relations[0]);
    assert(area.complete);
    assert(area.outerRingCount == 2);
    assert(area.innerRingCount == 1);
    assert(area.rings.length == 3);

    // Output follows deterministic first contributing member order per role,
    // never associative-array iteration order.
    assert(area.rings[0].segments[0].wayId == 11);
    assert(area.rings[1].segments[0].wayId == 10);
    assert(area.rings[2].segments[0].wayId == 12);
}

unittest
{
    import osm.model.owned :
        OwnedNode,
        OwnedNodeRef,
        OwnedTag;

    OwnedDataset dataset;

    foreach (id; 1L .. 6L)
    {
        OwnedNode node;
        node.id = id;
        dataset.nodes ~= node;
    }

    OwnedWay a;
    a.id = 10;
    a.nodes ~= OwnedNodeRef(1);
    a.nodes ~= OwnedNodeRef(2);
    dataset.ways ~= a;

    OwnedWay b;
    b.id = 11;
    b.nodes ~= OwnedNodeRef(2);
    b.nodes ~= OwnedNodeRef(3);
    dataset.ways ~= b;

    OwnedWay c;
    c.id = 12;
    c.nodes ~= OwnedNodeRef(2);
    c.nodes ~= OwnedNodeRef(4);
    dataset.ways ~= c;

    OwnedRelation relation;
    relation.id = 20;
    relation.tags ~= OwnedTag(
        cast(immutable(ubyte)[])"type",
        cast(immutable(ubyte)[])"multipolygon");
    foreach (wayId; [10L, 11L, 12L])
        relation.members ~= OwnedRelationMember(
            ElementType.way,
            wayId,
            cast(immutable(ubyte)[])"outer");
    dataset.relations ~= relation;

    import osm.validate : DatasetValidationIssue;
    DatasetValidationIssue issue;
    OwnedDatasetIndex index;
    assert(index.build(dataset, issue));

    auto area = assembleMultipolygon(
        dataset,
        index,
        dataset.relations[0]);
    assert(area.state == AreaAssemblyState.ambiguous);
    assert(area.openChains.length >= 1);

    bool sawAmbiguous;
    foreach (ref const problem; area.issues)
        if (problem.kind ==
            AreaAssemblyIssueKind.ambiguousJunction)
        {
            sawAmbiguous = true;
            assert(problem.nodeId == 2);
            assert(problem.candidateCount == 2);
        }
    assert(sawAmbiguous);
}

unittest
{
    import osm.model.owned :
        OwnedNode,
        OwnedNodeRef,
        OwnedTag;

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
    relation.tags ~= OwnedTag(
        cast(immutable(ubyte)[])"type",
        cast(immutable(ubyte)[])"multipolygon");
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        cast(immutable(ubyte)[])"outer");
    dataset.relations ~= relation;

    import osm.validate : DatasetValidationIssue;
    DatasetValidationIssue issue;
    OwnedDatasetIndex index;
    assert(index.build(dataset, issue));

    auto area = assembleMultipolygon(
        dataset,
        index,
        dataset.relations[0]);

    assert(area.state == AreaAssemblyState.partial);
    assert(area.rings.length == 1);
    assert(!area.rings[0].locationsComplete);
    assert(area.rings[0].vertices[1].nodeId == 999);
    assert(!area.rings[0].vertices[1].resolved);
}

unittest
{
    import osm.model.owned :
        OwnedTag;

    OwnedDataset dataset;

    OwnedRelation nested;
    nested.id = 21;
    dataset.relations ~= nested;

    OwnedRelation relation;
    relation.id = 20;
    relation.tags ~= OwnedTag(
        cast(immutable(ubyte)[])"type",
        cast(immutable(ubyte)[])"multipolygon");
    relation.members ~= OwnedRelationMember(
        ElementType.relation,
        21,
        cast(immutable(ubyte)[])"outer");
    dataset.relations ~= relation;

    import osm.validate : DatasetValidationIssue;
    DatasetValidationIssue issue;
    OwnedDatasetIndex index;
    assert(index.build(dataset, issue));

    auto area = assembleMultipolygon(
        dataset,
        index,
        dataset.relations[1]);

    assert(area.state == AreaAssemblyState.invalid);
    assert(area.rings.length == 0);

    bool sawUnsupported;
    foreach (ref const problem; area.issues)
        if (problem.kind ==
            AreaAssemblyIssueKind.unsupportedMemberType)
            sawUnsupported = true;
    assert(sawUnsupported);
}
