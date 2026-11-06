/**
 * M15 real-workload dataset/topology qualification.
 *
 * The program loads one pinned real PBF into OsmStore once, then measures the
 * consumer-visible validation/resolution/closure operations without timing PBF
 * I/O. It also derives complete and deliberately partial subsets from real Way
 * data and verifies parent closure after a supported store edit/revert.
 */
module osm.benchmark.topology.qualification;

import osm :
    ElementType,
    OsmHandle,
    OsmId,
    OsmStore,
    OwnedDataset,
    OwnedNode,
    OwnedNodeRef,
    OwnedRelation,
    OwnedRelationMember,
    OwnedWay,
    PbfReadSummary,
    PbfStoreReadStatus,
    StoreCounts,
    StoreRelationView,
    StoreStatus,
    StoreWayView,
    readPbfStore;
import osm.topology :
    OwnedChildVisit,
    OwnedDatasetIndex,
    ReferenceResolutionState,
    StoreChildVisit,
    StoreParentVisit,
    TopologyTraversalError,
    TopologyTraversalLimits,
    TopologyTraversalStatus,
    TopologyTraversalWorkspace,
    resolveMembers,
    resolveNodes,
    walkParentClosure,
    walkRelationClosure;
import osm.validate :
    DatasetValidationError,
    DatasetValidationIssue,
    DatasetValidationMode,
    validateDataset;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : stderr, writeln, writefln;

private enum defaultRounds = 5;

private void require(bool condition, string message)
{
    if (!condition)
        throw new Exception(message);
}

private long elapsedNs(scope void delegate() operation) @trusted
{
    StopWatch sw = StopWatch(AutoStart.yes);
    operation();
    sw.stop();
    return sw.peek.total!"nsecs";
}

private long medianNs(long[] values)
{
    sort(values);
    return values[values.length / 2];
}

private void mix(ref ulong hash, ulong value) @safe pure nothrow @nogc
{
    hash ^= value + 0x9e3779b97f4a7c15UL + (hash << 6) + (hash >> 2);
}

private struct SelectedWay
{
    OsmHandle handle;
    OsmId id;
    size_t nodes;
}

private struct SelectedRelation
{
    OsmHandle handle;
    OsmId id;
    size_t members;
    bool hasResolvedRelationMember;
}

private SelectedWay selectLargestWay(OsmStore store) @safe
{
    SelectedWay result;

    auto ways = store.ways;
    while (!ways.empty)
    {
        auto way = ways.front;
        if (way.nodes.length > result.nodes)
        {
            result.handle = way.handle;
            result.id = way.id;
            result.nodes = way.nodes.length;
        }
        ways.popFront();
    }

    require(result.handle.valid, "real workload has no Way");
    require(result.nodes > 0, "largest real Way has no Node references");
    return result;
}

private SelectedRelation selectRelations(
    OsmStore store,
    out SelectedRelation largestNested) @safe
{
    SelectedRelation largest;
    largestNested = SelectedRelation.init;

    auto relations = store.relations;
    while (!relations.empty)
    {
        auto relation = relations.front;
        const memberCount = relation.members.length;

        if (memberCount > largest.members)
        {
            largest.handle = relation.handle;
            largest.id = relation.id;
            largest.members = memberCount;
        }

        bool hasResolvedNested;
        auto members = store.resolveMembers(relation);
        while (!members.empty)
        {
            auto resolved = members.front;
            if (resolved.member.type == ElementType.relation &&
                resolved.resolved)
            {
                hasResolvedNested = true;
                break;
            }
            members.popFront();
        }

        if (hasResolvedNested &&
            (!largestNested.handle.valid ||
             memberCount > largestNested.members))
        {
            largestNested.handle = relation.handle;
            largestNested.id = relation.id;
            largestNested.members = memberCount;
            largestNested.hasResolvedRelationMember = true;
        }

        relations.popFront();
    }

    require(largest.handle.valid, "real workload has no Relation");

    if (!largestNested.handle.valid)
        largestNested = largest;

    return largest;
}

private struct ValidationResult
{
    bool valid;
    DatasetValidationError error;
    ElementType elementType;
    OsmId elementId;
    ElementType referenceType;
    OsmId referenceId;
}

private ValidationResult validationResult(
    OsmStore store,
    DatasetValidationMode mode) @safe
{
    DatasetValidationIssue issue;
    ValidationResult result;
    result.valid = validateDataset(store, mode, issue);
    result.error = issue.error;
    result.elementType = issue.elementType;
    result.elementId = issue.elementId;
    result.referenceType = issue.referenceType;
    result.referenceId = issue.referenceId;
    return result;
}

private long timeValidation(
    OsmStore store,
    DatasetValidationMode mode,
    size_t rounds,
    out ValidationResult reference) @safe
{
    // Untimed warm-up.
    reference = validationResult(store, mode);

    long[] samples = new long[rounds];
    foreach (i; 0 .. rounds)
    {
        ValidationResult current;
        samples[i] = elapsedNs({
            current = validationResult(store, mode);
        });
        require(current == reference, "validation result changed between rounds");
    }

    return medianNs(samples);
}

private struct ResolutionSummary
{
    size_t refs;
    size_t resolved;
    size_t unresolved;
    ulong checksum;
}

private ResolutionSummary summarizeWay(
    OsmStore store,
    OsmHandle handle) @safe
{
    StoreStatus status;
    StoreWayView way;
    require(store.way(handle, way, status), "selected Way became unavailable");

    ResolutionSummary result;
    result.checksum = 0x243f6a8885a308d3UL;

    auto refs = store.resolveNodes(way);
    while (!refs.empty)
    {
        auto value = refs.front;
        ++result.refs;
        if (value.resolved)
            ++result.resolved;
        else
            ++result.unresolved;
        mix(result.checksum, cast(ulong)value.reference.id);
        mix(result.checksum, cast(ulong)value.state);
        refs.popFront();
    }

    return result;
}

private ResolutionSummary summarizeRelation(
    OsmStore store,
    OsmHandle handle) @safe
{
    StoreStatus status;
    StoreRelationView relation;
    require(
        store.relation(handle, relation, status),
        "selected Relation became unavailable");

    ResolutionSummary result;
    result.checksum = 0x13198a2e03707344UL;

    auto members = store.resolveMembers(relation);
    while (!members.empty)
    {
        auto value = members.front;
        ++result.refs;
        if (value.resolved)
            ++result.resolved;
        else
            ++result.unresolved;
        mix(result.checksum, cast(ulong)cast(ubyte)value.member.type);
        mix(result.checksum, cast(ulong)value.member.id);
        mix(result.checksum, cast(ulong)value.state);
        members.popFront();
    }

    return result;
}

private long timeWayResolution(
    OsmStore store,
    OsmHandle handle,
    size_t rounds,
    out ResolutionSummary reference) @safe
{
    reference = summarizeWay(store, handle);

    long[] samples = new long[rounds];
    foreach (i; 0 .. rounds)
    {
        ResolutionSummary current;
        samples[i] = elapsedNs({
            current = summarizeWay(store, handle);
        });
        require(current == reference, "Way resolution changed between rounds");
    }
    return medianNs(samples);
}

private long timeRelationResolution(
    OsmStore store,
    OsmHandle handle,
    size_t rounds,
    out ResolutionSummary reference) @safe
{
    reference = summarizeRelation(store, handle);

    long[] samples = new long[rounds];
    foreach (i; 0 .. rounds)
    {
        ResolutionSummary current;
        samples[i] = elapsedNs({
            current = summarizeRelation(store, handle);
        });
        require(
            current == reference,
            "Relation resolution changed between rounds");
    }
    return medianNs(samples);
}

private struct ClosureSummary
{
    bool ok;
    bool completed;
    TopologyTraversalError error;
    size_t visits;
    size_t relationsExpanded;
    size_t maxDepth;
    size_t unresolved;
    ulong checksum;
}

private ClosureSummary summarizeClosure(
    OsmStore store,
    OsmHandle relation,
    ref TopologyTraversalWorkspace workspace,
    TopologyTraversalLimits limits) @safe
{
    ClosureSummary result;
    result.checksum = 0xa4093822299f31d0UL;

    int collect(scope ref const StoreChildVisit visit) @safe
    {
        if (visit.resolution != ReferenceResolutionState.resolved)
            ++result.unresolved;
        mix(result.checksum, cast(ulong)cast(ubyte)visit.parentType);
        mix(result.checksum, cast(ulong)visit.parentId);
        mix(result.checksum, visit.childIndex);
        mix(result.checksum, cast(ulong)cast(ubyte)visit.type);
        mix(result.checksum, cast(ulong)visit.id);
        mix(result.checksum, visit.depth);
        mix(result.checksum, cast(ulong)visit.resolution);
        mix(result.checksum, visit.relationPreviouslyExpanded);
        return 0;
    }

    TopologyTraversalStatus status;
    result.ok = walkRelationClosure(
        store,
        relation,
        workspace,
        limits,
        &collect,
        status);
    result.completed = status.completed;
    result.error = status.error;
    result.visits = status.visits;
    result.relationsExpanded = status.relationsExpanded;
    result.maxDepth = status.maxDepthReached;
    return result;
}

private long timeClosure(
    OsmStore store,
    OsmHandle relation,
    size_t rounds,
    out ClosureSummary reference) @safe
{
    TopologyTraversalLimits limits;
    limits.maxDepth = 128;
    limits.maxVisits = 2_000_000;
    limits.maxRelations = 200_000;

    TopologyTraversalWorkspace workspace;
    reference = summarizeClosure(store, relation, workspace, limits);

    long[] samples = new long[rounds];
    foreach (i; 0 .. rounds)
    {
        ClosureSummary current;
        samples[i] = elapsedNs({
            current = summarizeClosure(store, relation, workspace, limits);
        });
        require(current == reference, "closure result changed between rounds");
    }
    return medianNs(samples);
}

private struct ParentSummary
{
    bool ok;
    bool completed;
    TopologyTraversalError error;
    size_t visits;
    size_t relationsExpanded;
    size_t maxDepth;
    ulong checksum;
}

private ParentSummary summarizeParents(
    OsmStore store,
    ElementType type,
    OsmId id,
    ref TopologyTraversalWorkspace workspace) @safe
{
    ParentSummary result;
    result.checksum = 0x082efa98ec4e6c89UL;

    int collect(scope ref const StoreParentVisit visit) @safe
    {
        mix(result.checksum, cast(ulong)cast(ubyte)visit.type);
        mix(result.checksum, cast(ulong)visit.id);
        mix(result.checksum, visit.depth);
        return 0;
    }

    TopologyTraversalLimits limits;
    TopologyTraversalStatus status;
    result.ok = walkParentClosure(
        store,
        type,
        id,
        workspace,
        limits,
        &collect,
        status);
    result.completed = status.completed;
    result.error = status.error;
    result.visits = status.visits;
    result.relationsExpanded = status.relationsExpanded;
    result.maxDepth = status.maxDepthReached;
    return result;
}

private long timeParents(
    OsmStore store,
    ElementType type,
    OsmId id,
    size_t rounds,
    out ParentSummary reference) @safe
{
    TopologyTraversalWorkspace workspace;
    reference = summarizeParents(store, type, id, workspace);

    long[] samples = new long[rounds];
    foreach (i; 0 .. rounds)
    {
        ParentSummary current;
        samples[i] = elapsedNs({
            current = summarizeParents(store, type, id, workspace);
        });
        require(
            current == reference,
            "parent closure changed between rounds");
    }
    return medianNs(samples);
}

private bool buildRealSubsets(
    OsmStore store,
    SelectedWay selected,
    out OwnedDataset completeSubset,
    out OwnedDataset partialSubset,
    out OsmId parentProbeNode) @safe
{
    StoreStatus status;
    OwnedWay way;
    if (!store.copyWay(selected.handle, way, status))
        return false;

    partialSubset.ways ~= way.deepCopy();

    bool[OsmId] seen;
    completeSubset.ways ~= way.deepCopy();

    foreach (ref const nodeRef; way.nodes)
    {
        if (nodeRef.id in seen)
            continue;
        seen[nodeRef.id] = true;

        OsmHandle nodeHandle;
        if (!store.find(ElementType.node, nodeRef.id, nodeHandle))
            return false;

        OwnedNode node;
        if (!store.copyNode(nodeHandle, node, status))
            return false;

        completeSubset.nodes ~= node;
        if (parentProbeNode == 0)
            parentProbeNode = node.id;
    }

    return parentProbeNode != 0;
}

private bool parentClosureContainsWay(
    OsmStore store,
    OsmId nodeId,
    OsmId wayId) @safe
{
    TopologyTraversalWorkspace workspace;
    TopologyTraversalLimits limits;
    TopologyTraversalStatus status;
    bool found;

    int inspect(scope ref const StoreParentVisit visit) @safe
    {
        if (visit.type == ElementType.way && visit.id == wayId)
            found = true;
        return 0;
    }

    if (!walkParentClosure(
            store,
            ElementType.node,
            nodeId,
            workspace,
            limits,
            &inspect,
            status))
        return false;
    return status.completed && found;
}

private bool qualifyParentEdit(
    OsmStore store,
    SelectedWay selected,
    out OsmId oldNodeId,
    out OsmId replacementNodeId) @safe
{
    StoreStatus status;
    OwnedWay original;
    if (!store.copyWay(selected.handle, original, status))
        return false;

    size_t oldIndex = size_t.max;
    size_t replacementIndex = size_t.max;

    foreach (i, ref const candidate; original.nodes)
    {
        size_t occurrences;
        foreach (ref const other; original.nodes)
            if (other.id == candidate.id)
                ++occurrences;

        if (occurrences != 1)
            continue;

        foreach (j, ref const replacement; original.nodes)
        {
            if (replacement.id != candidate.id)
            {
                oldIndex = i;
                replacementIndex = j;
                break;
            }
        }

        if (oldIndex != size_t.max)
            break;
    }

    if (oldIndex == size_t.max)
        return false;

    oldNodeId = original.nodes[oldIndex].id;
    replacementNodeId = original.nodes[replacementIndex].id;

    if (!parentClosureContainsWay(store, oldNodeId, selected.id))
        return false;

    OwnedWay edited = original.deepCopy();
    edited.nodes[oldIndex].id = replacementNodeId;

    if (!store.replace(selected.handle, edited, status))
        return false;

    const removed =
        !parentClosureContainsWay(store, oldNodeId, selected.id);
    const replacementPresent =
        parentClosureContainsWay(store, replacementNodeId, selected.id);

    if (!store.revert(selected.handle, status))
        return false;

    const restored =
        parentClosureContainsWay(store, oldNodeId, selected.id);

    return removed && replacementPresent && restored;
}

private bool qualifyAdversarialDepth() @safe
{
    OwnedDataset data;
    enum relationCount = 24;

    foreach (i; 0 .. relationCount)
    {
        OwnedRelation relation;
        relation.id = 1 + cast(long)i;

        if (i + 1 < relationCount)
        {
            relation.members ~= OwnedRelationMember(
                ElementType.relation,
                2 + cast(long)i,
                null);
        }

        data.relations ~= relation;
    }

    OwnedDatasetIndex index;
    DatasetValidationIssue issue;
    if (!index.build(data, issue))
        return false;

    TopologyTraversalWorkspace workspace;
    TopologyTraversalLimits limits;
    limits.maxDepth = 8;

    TopologyTraversalStatus status;
    int noop(scope ref const OwnedChildVisit visit) @safe
    {
        return 0;
    }

    const ok = walkRelationClosure(
        data,
        index,
        1,
        workspace,
        limits,
        &noop,
        status);

    return !ok &&
           status.error == TopologyTraversalError.depthLimit &&
           !status.completed;
}

private bool qualifyCycle() @safe
{
    OwnedDataset data;

    OwnedRelation a;
    a.id = 1;
    a.members ~= OwnedRelationMember(
        ElementType.relation,
        2,
        null);
    data.relations ~= a;

    OwnedRelation b;
    b.id = 2;
    b.members ~= OwnedRelationMember(
        ElementType.relation,
        1,
        null);
    data.relations ~= b;

    OwnedDatasetIndex index;
    DatasetValidationIssue issue;
    if (!index.build(data, issue))
        return false;

    TopologyTraversalWorkspace workspace;
    TopologyTraversalLimits limits;
    TopologyTraversalStatus status;
    size_t visits;
    size_t repeated;

    int collect(scope ref const OwnedChildVisit visit) @safe
    {
        ++visits;
        if (visit.relationPreviouslyExpanded)
            ++repeated;
        return 0;
    }

    const ok = walkRelationClosure(
        data,
        index,
        1,
        workspace,
        limits,
        &collect,
        status);

    return ok &&
           status.completed &&
           visits == 2 &&
           repeated == 1 &&
           status.relationsExpanded == 2;
}

private int run(string filename, size_t rounds)
{
    auto storage = cast(ubyte[])read(filename);

    OsmStore store;
    PbfReadSummary readSummary;
    PbfStoreReadStatus readStatus;
    require(
        readPbfStore(storage, store, readSummary, readStatus),
        "direct PBF-to-store load failed");

    const counts = store.counts;
    writefln("dataset=%s", filename);
    writefln("nodes=%s", counts.liveNodes);
    writefln("ways=%s", counts.liveWays);
    writefln("relations=%s", counts.liveRelations);

    ValidationResult partialValidation;
    const partialValidationP50 = timeValidation(
        store,
        DatasetValidationMode.partial,
        rounds,
        partialValidation);
    require(
        partialValidation.valid,
        "real store failed partial dataset validation");

    ValidationResult completeValidation;
    const completeValidationP50 = timeValidation(
        store,
        DatasetValidationMode.complete,
        rounds,
        completeValidation);

    writefln("partial_store_validation=pass");
    writefln(
        "partial_store_validation_p50_ns=%s",
        partialValidationP50);
    writefln(
        "complete_store_validation=%s",
        completeValidation.valid ? "pass" : "partial-extract");
    writefln(
        "complete_store_validation_error=%s",
        completeValidation.error);
    writefln(
        "complete_store_validation_reference_type=%s",
        completeValidation.referenceType);
    writefln(
        "complete_store_validation_reference_id=%s",
        completeValidation.referenceId);
    writefln(
        "complete_store_validation_p50_ns=%s",
        completeValidationP50);

    const largestWay = selectLargestWay(store);
    SelectedRelation nestedRelation;
    const largestRelation = selectRelations(store, nestedRelation);

    writefln("largest_way_id=%s", largestWay.id);
    writefln("largest_way_nodes=%s", largestWay.nodes);
    writefln("largest_relation_id=%s", largestRelation.id);
    writefln("largest_relation_members=%s", largestRelation.members);
    writefln("closure_root_relation_id=%s", nestedRelation.id);
    writefln(
        "closure_root_has_resolved_relation_member=%s",
        nestedRelation.hasResolvedRelationMember ? 1 : 0);

    ResolutionSummary wayResolution;
    const wayResolutionP50 = timeWayResolution(
        store,
        largestWay.handle,
        rounds,
        wayResolution);
    require(
        wayResolution.refs == largestWay.nodes,
        "Way resolution lost/reordered reference count");

    writefln("way_resolution_integrity=pass");
    writefln("way_resolution_refs=%s", wayResolution.refs);
    writefln("way_resolution_resolved=%s", wayResolution.resolved);
    writefln("way_resolution_unresolved=%s", wayResolution.unresolved);
    writefln("way_resolution_checksum=%s", wayResolution.checksum);
    writefln("way_resolution_p50_ns=%s", wayResolutionP50);

    ResolutionSummary relationResolution;
    const relationResolutionP50 = timeRelationResolution(
        store,
        largestRelation.handle,
        rounds,
        relationResolution);
    require(
        relationResolution.refs == largestRelation.members,
        "Relation resolution lost/reordered member count");

    writefln("relation_resolution_integrity=pass");
    writefln("relation_resolution_refs=%s", relationResolution.refs);
    writefln(
        "relation_resolution_resolved=%s",
        relationResolution.resolved);
    writefln(
        "relation_resolution_unresolved=%s",
        relationResolution.unresolved);
    writefln(
        "relation_resolution_checksum=%s",
        relationResolution.checksum);
    writefln(
        "relation_resolution_p50_ns=%s",
        relationResolutionP50);

    ClosureSummary closure;
    const closureP50 = timeClosure(
        store,
        nestedRelation.handle,
        rounds,
        closure);
    require(closure.ok, "real Relation closure failed");
    require(closure.completed, "real Relation closure did not complete");

    writefln("closure_integrity=pass");
    writefln("closure_visits=%s", closure.visits);
    writefln(
        "closure_relations_expanded=%s",
        closure.relationsExpanded);
    writefln("closure_max_depth=%s", closure.maxDepth);
    writefln("closure_unresolved=%s", closure.unresolved);
    writefln("closure_checksum=%s", closure.checksum);
    writefln("closure_p50_ns=%s", closureP50);

    OwnedDataset completeSubset;
    OwnedDataset partialSubset;
    OsmId parentProbeNode;
    require(
        buildRealSubsets(
            store,
            largestWay,
            completeSubset,
            partialSubset,
            parentProbeNode),
        "could not derive real complete/partial Way subsets");

    DatasetValidationIssue subsetIssue;
    require(
        validateDataset(
            completeSubset,
            DatasetValidationMode.complete,
            subsetIssue),
        "real complete Way subset failed complete validation");
    writefln("real_complete_subset_validation=pass");

    require(
        validateDataset(
            partialSubset,
            DatasetValidationMode.partial,
            subsetIssue),
        "real partial Way subset failed partial validation");
    writefln("real_partial_subset_validation=pass");

    const partialCompleteAccepted = validateDataset(
        partialSubset,
        DatasetValidationMode.complete,
        subsetIssue);
    require(
        !partialCompleteAccepted &&
        subsetIssue.error == DatasetValidationError.missingReference,
        "real partial Way subset was not rejected by complete mode");
    writefln("real_partial_subset_complete_rejected=pass");

    ParentSummary parentSummary;
    const parentP50 = timeParents(
        store,
        ElementType.node,
        parentProbeNode,
        rounds,
        parentSummary);
    require(parentSummary.ok && parentSummary.completed,
        "real parent closure failed");

    writefln("parent_closure_integrity=pass");
    writefln("parent_closure_root_node=%s", parentProbeNode);
    writefln("parent_closure_visits=%s", parentSummary.visits);
    writefln("parent_closure_checksum=%s", parentSummary.checksum);
    writefln("parent_closure_p50_ns=%s", parentP50);

    OsmId oldNodeId;
    OsmId replacementNodeId;
    require(
        qualifyParentEdit(
            store,
            largestWay,
            oldNodeId,
            replacementNodeId),
        "parent closure/indexes became stale across Way edit/revert");

    writefln("parent_edit_integrity=pass");
    writefln("parent_edit_old_node=%s", oldNodeId);
    writefln("parent_edit_replacement_node=%s", replacementNodeId);

    require(
        qualifyAdversarialDepth(),
        "bounded depth qualification failed");
    writefln("bounded_depth_integrity=pass");

    require(qualifyCycle(), "cycle qualification failed");
    writefln("cycle_integrity=pass");

    return 0;
}

int main(string[] args)
{
    if (args.length < 2 || args.length > 3)
    {
        stderr.writeln(
            "usage: osm-d-bench-topology-qualification <file.osm.pbf> [rounds]");
        return 2;
    }

    size_t rounds = defaultRounds;
    if (args.length == 3)
        rounds = to!size_t(args[2]);

    if (rounds == 0)
    {
        stderr.writeln("rounds must be > 0");
        return 2;
    }

    try
    {
        return run(args[1], rounds);
    }
    catch (Exception e)
    {
        stderr.writefln("qualification failed: %s", e.msg);
        return 1;
    }
}
