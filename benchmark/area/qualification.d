/**
 * M16 real-workload complete-object and OSM area qualification.
 *
 * Loads one pinned PBF into OsmStore before timing. The program scans real
 * complete objects and multipolygon Relations, checks deterministic assembly,
 * measures representative repeated-use latency/allocation, derives real
 * partial extracts, and optionally compares ring counts with an independent
 * osmium-export reference TSV.
 */
module osm.benchmark.area.qualification;

import core.memory : GC;

import osm :
    ElementType,
    LocationView,
    OsmHandle,
    OsmId,
    OsmStore,
    OwnedDataset,
    OwnedNode,
    OwnedRelation,
    OwnedWay,
    PbfReadSummary,
    PbfStoreReadStatus,
    StoreNodeView,
    StoreRelationView,
    StoreStatus,
    StoreWayView,
    readPbfStore;
import osm.area :
    AreaAssemblyIssue,
    AreaAssemblyResult,
    AreaAssemblyState,
    AreaOpenChain,
    AreaRing,
    AreaRingRole,
    AreaRingSegment,
    AreaVertex,
    assembleClosedWayArea,
    assembleMultipolygon;
import osm.complete :
    CompleteObjectState,
    LocationBounds,
    completeStatus,
    completeWay,
    isClosedWay,
    locationBounds;
import osm.topology : OwnedDatasetIndex;
import osm.validate : DatasetValidationIssue;
import osm.view.tag : tagEquals;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read, readText;
import std.stdio : stderr, writefln;
import std.string : split, splitLines, strip;

private enum defaultRounds = 5;

private void require(bool condition, string message) @safe
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

private long medianNs(long[] values) @safe
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

private struct SelectedArea
{
    OsmHandle handle;
    OsmId id;
    size_t members;
    size_t rings;
    size_t segments;
}

private struct ReferenceArea
{
    size_t outer;
    size_t inner;
}

private ReferenceArea[OsmId] readReference(string filename)
{
    ReferenceArea[OsmId] result;
    if (filename.length == 0)
        return result;

    foreach (rawLine; readText(filename).splitLines)
    {
        const line = rawLine.strip;
        if (line.length == 0 || line[0] == '#')
            continue;

        auto fields = line.split("\t");
        require(fields.length == 3, "invalid osmium reference TSV row");

        const id = fields[0].to!OsmId;
        require(id != 0, "reference TSV contains zero Relation ID");
        require((id in result) is null, "reference TSV contains duplicate Relation ID");

        result[id] = ReferenceArea(
            fields[1].to!size_t,
            fields[2].to!size_t);
    }

    return result;
}

private SelectedWay selectLargestCompleteWay(OsmStore store) @safe
{
    SelectedWay result;

    auto ways = store.ways;
    while (!ways.empty)
    {
        auto way = ways.front;
        ways.popFront();

        if (way.nodes.length == 0 ||
            (result.handle.valid && way.nodes.length <= result.nodes))
            continue;

        const status = completeStatus(completeWay(store, way));
        if (status.state != CompleteObjectState.complete)
            continue;

        result = SelectedWay(way.handle, way.id, way.nodes.length);
    }

    require(result.handle.valid, "real workload has no complete Way");
    return result;
}

private SelectedWay selectLargestClosedCompleteWay(OsmStore store) @safe
{
    SelectedWay result;

    auto ways = store.ways;
    while (!ways.empty)
    {
        auto way = ways.front;
        ways.popFront();

        if (way.nodes.length < 2 ||
            (result.handle.valid && way.nodes.length <= result.nodes) ||
            !isClosedWay(way))
            continue;

        const status = completeStatus(completeWay(store, way));
        if (status.state != CompleteObjectState.complete)
            continue;

        result = SelectedWay(way.handle, way.id, way.nodes.length);
    }

    require(result.handle.valid, "real workload has no closed complete Way");
    return result;
}

private struct CompleteWaySummary
{
    size_t nodes;
    bool closed;
    bool complete;
    bool boundsEmpty;
    long minLat;
    long minLon;
    long maxLat;
    long maxLon;
    ulong checksum;
}

private CompleteWaySummary summarizeCompleteWay(
    OsmStore store,
    OsmHandle handle) @safe
{
    StoreStatus status;
    StoreWayView way;
    require(store.way(handle, way, status), "selected Way became unavailable");

    auto full = completeWay(store, way);
    auto objectStatus = completeStatus(full);

    LocationBounds bounds;
    auto boundsStatus = locationBounds(full, bounds);

    CompleteWaySummary result;
    result.nodes = full.nodes.length;
    result.closed = full.isClosed;
    result.complete =
        objectStatus.state == CompleteObjectState.complete &&
        boundsStatus.state == CompleteObjectState.complete;
    result.boundsEmpty = bounds.empty;
    result.checksum = 0x6a09e667f3bcc909UL;

    if (!bounds.empty)
    {
        result.minLat = bounds.minLatitudeNanodegrees;
        result.minLon = bounds.minLongitudeNanodegrees;
        result.maxLat = bounds.maxLatitudeNanodegrees;
        result.maxLon = bounds.maxLongitudeNanodegrees;
    }

    auto nodes = full.nodes;
    while (!nodes.empty)
    {
        auto node = nodes.front;
        mix(result.checksum, cast(ulong)node.reference.id);
        mix(result.checksum, cast(ulong)node.state);
        if (node.resolved)
        {
            mix(
                result.checksum,
                cast(ulong)node.location.latitudeNanodegrees);
            mix(
                result.checksum,
                cast(ulong)node.location.longitudeNanodegrees);
        }
        nodes.popFront();
    }

    return result;
}

private long timeCompleteWay(
    OsmStore store,
    OsmHandle handle,
    size_t rounds,
    out CompleteWaySummary reference) @safe
{
    reference = summarizeCompleteWay(store, handle);

    long[] samples = new long[rounds];
    foreach (i; 0 .. rounds)
    {
        CompleteWaySummary current;
        samples[i] = elapsedNs({
            current = summarizeCompleteWay(store, handle);
        });
        require(current == reference, "complete Way result changed between rounds");
    }

    return medianNs(samples);
}

private ulong areaChecksum(scope ref const AreaAssemblyResult area)
    @safe pure nothrow @nogc
{
    ulong hash = 0xbb67ae8584caa73bUL;
    mix(hash, cast(ulong)area.state);
    mix(hash, cast(ulong)cast(ubyte)area.sourceType);
    mix(hash, cast(ulong)area.sourceId);
    mix(hash, area.rings.length);
    mix(hash, area.openChains.length);
    mix(hash, area.issues.length);

    foreach (ref const ring; area.rings)
    {
        mix(hash, cast(ulong)ring.role);
        mix(hash, ring.vertices.length);
        mix(hash, ring.segments.length);
        mix(hash, ring.locationsComplete);

        foreach (ref const vertex; ring.vertices)
        {
            mix(hash, cast(ulong)vertex.nodeId);
            mix(hash, cast(ulong)vertex.state);
            if (vertex.resolved)
            {
                mix(
                    hash,
                    cast(ulong)vertex.location.latitudeNanodegrees);
                mix(
                    hash,
                    cast(ulong)vertex.location.longitudeNanodegrees);
            }
        }

        foreach (ref const segment; ring.segments)
        {
            mix(hash, cast(ulong)segment.wayId);
            mix(hash, segment.hasMemberIndex);
            mix(hash, segment.memberIndex);
            mix(hash, segment.reversed);
            mix(hash, segment.firstVertex);
            mix(hash, segment.vertexCount);
        }
    }

    foreach (ref const chain; area.openChains)
    {
        mix(hash, cast(ulong)chain.role);
        mix(hash, chain.vertices.length);
        mix(hash, chain.segments.length);
        mix(hash, chain.locationsComplete);

        foreach (ref const vertex; chain.vertices)
        {
            mix(hash, cast(ulong)vertex.nodeId);
            mix(hash, cast(ulong)vertex.state);
        }

        foreach (ref const segment; chain.segments)
        {
            mix(hash, cast(ulong)segment.wayId);
            mix(hash, segment.memberIndex);
            mix(hash, segment.reversed);
        }
    }

    foreach (ref const issue; area.issues)
    {
        mix(hash, cast(ulong)issue.kind);
        mix(hash, cast(ulong)issue.role);
        mix(hash, issue.memberIndex);
        mix(hash, cast(ulong)cast(ubyte)issue.memberType);
        mix(hash, cast(ulong)issue.memberId);
        mix(hash, cast(ulong)issue.nodeId);
        mix(hash, issue.childIndex);
        mix(hash, issue.candidateCount);
        mix(hash, cast(ulong)issue.resolution);
    }

    return hash;
}

private size_t visibleAreaPayloadBytes(scope ref const AreaAssemblyResult area)
    @safe pure nothrow @nogc
{
    size_t bytes =
        area.rings.length * AreaRing.sizeof +
        area.openChains.length * AreaOpenChain.sizeof +
        area.issues.length * AreaAssemblyIssue.sizeof;

    foreach (ref const ring; area.rings)
    {
        bytes += ring.vertices.length * AreaVertex.sizeof;
        bytes += ring.segments.length * AreaRingSegment.sizeof;
    }

    foreach (ref const chain; area.openChains)
    {
        bytes += chain.vertices.length * AreaVertex.sizeof;
        bytes += chain.segments.length * AreaRingSegment.sizeof;
    }

    return bytes;
}

private struct AreaSummary
{
    AreaAssemblyState state;
    size_t rings;
    size_t outer;
    size_t inner;
    size_t openChains;
    size_t issues;
    size_t vertices;
    size_t segments;
    bool locationsComplete;
    ulong checksum;
}

private AreaSummary summarizeArea(scope ref const AreaAssemblyResult area)
    @safe pure nothrow @nogc
{
    AreaSummary result;
    result.state = area.state;
    result.rings = area.rings.length;
    result.outer = area.outerRingCount;
    result.inner = area.innerRingCount;
    result.openChains = area.openChains.length;
    result.issues = area.issues.length;
    result.locationsComplete = true;
    result.checksum = areaChecksum(area);

    foreach (ref const ring; area.rings)
    {
        result.vertices += ring.vertices.length;
        result.segments += ring.segments.length;
        if (!ring.locationsComplete)
            result.locationsComplete = false;
    }

    foreach (ref const chain; area.openChains)
    {
        result.vertices += chain.vertices.length;
        result.segments += chain.segments.length;
        if (!chain.locationsComplete)
            result.locationsComplete = false;
    }

    return result;
}

private AreaSummary summarizeRelationArea(
    OsmStore store,
    OsmHandle handle) @safe
{
    StoreStatus status;
    StoreRelationView relation;
    require(
        store.relation(handle, relation, status),
        "selected multipolygon became unavailable");

    auto area = assembleMultipolygon(store, relation);
    return summarizeArea(area);
}

private long timeRelationArea(
    OsmStore store,
    OsmHandle handle,
    size_t rounds,
    out AreaSummary reference) @safe
{
    reference = summarizeRelationArea(store, handle);

    long[] samples = new long[rounds];
    foreach (i; 0 .. rounds)
    {
        AreaSummary current;
        samples[i] = elapsedNs({
            current = summarizeRelationArea(store, handle);
        });
        require(current == reference, "multipolygon assembly changed between rounds");
    }

    return medianNs(samples);
}

private AreaSummary summarizeClosedWayArea(
    OsmStore store,
    OsmHandle handle) @safe
{
    StoreStatus status;
    StoreWayView way;
    require(store.way(handle, way, status), "selected closed Way became unavailable");

    auto area = assembleClosedWayArea(store, way);
    return summarizeArea(area);
}

private long timeClosedWayArea(
    OsmStore store,
    OsmHandle handle,
    size_t rounds,
    out AreaSummary reference) @safe
{
    reference = summarizeClosedWayArea(store, handle);

    long[] samples = new long[rounds];
    foreach (i; 0 .. rounds)
    {
        AreaSummary current;
        samples[i] = elapsedNs({
            current = summarizeClosedWayArea(store, handle);
        });
        require(current == reference, "closed Way assembly changed between rounds");
    }

    return medianNs(samples);
}

private struct MultipolygonScan
{
    size_t total;
    size_t complete;
    size_t partial;
    size_t ambiguous;
    size_t invalid;

    size_t completeFragmented;
    size_t completeMultipleOuter;
    size_t completeWithInner;

    size_t rings;
    size_t outerRings;
    size_t innerRings;
    size_t openChains;
    size_t issues;
    size_t vertices;
    size_t segments;

    size_t referenceTotal;
    size_t referenceOverlap;
    size_t referenceCompleteOverlap;
    size_t referenceRingMismatches;
    size_t referenceAcceptedButNotComplete;
    size_t completeNotReference;

    ulong checksum;

    SelectedArea largestComplete;
    SelectedArea largestFragmented;
}

private void countState(
    AreaAssemblyState state,
    ref MultipolygonScan result)
    @safe pure nothrow @nogc
{
    final switch (state)
    {
        case AreaAssemblyState.notAssembled:
            break;
        case AreaAssemblyState.complete:
            ++result.complete;
            break;
        case AreaAssemblyState.partial:
            ++result.partial;
            break;
        case AreaAssemblyState.ambiguous:
            ++result.ambiguous;
            break;
        case AreaAssemblyState.invalid:
            ++result.invalid;
            break;
    }
}

private bool fragmented(scope ref const AreaAssemblyResult area)
    @safe pure nothrow @nogc
{
    foreach (ref const ring; area.rings)
        if (ring.segments.length > 1)
            return true;
    return false;
}

private MultipolygonScan scanMultipolygons(
    OsmStore store,
    scope const(ReferenceArea[OsmId]) reference)
    @safe
{
    MultipolygonScan result;
    result.referenceTotal = reference.length;
    result.checksum = 0x3c6ef372fe94f82bUL;

    auto relations = store.relations;
    while (!relations.empty)
    {
        auto relation = relations.front;
        relations.popFront();

        if (!tagEquals(relation.tags, "type", "multipolygon"))
            continue;

        ++result.total;

        auto area = assembleMultipolygon(store, relation);
        countState(area.state, result);

        const summary = summarizeArea(area);

        result.rings += summary.rings;
        result.outerRings += summary.outer;
        result.innerRings += summary.inner;
        result.openChains += summary.openChains;
        result.issues += summary.issues;
        result.vertices += summary.vertices;
        result.segments += summary.segments;

        mix(result.checksum, cast(ulong)relation.id);
        mix(result.checksum, relation.members.length);
        mix(result.checksum, summary.checksum);

        const isFragmented = fragmented(area);

        if (area.state == AreaAssemblyState.complete)
        {
            require(area.openChains.length == 0, "complete area retained an open chain");
            foreach (ref const ring; area.rings)
            {
                require(ring.closed, "complete area contains an unclosed ring");
                require(ring.locationsComplete, "complete area has incomplete locations");
            }

            if (isFragmented)
                ++result.completeFragmented;
            if (area.outerRingCount > 1)
                ++result.completeMultipleOuter;
            if (area.innerRingCount > 0)
                ++result.completeWithInner;

            const candidate = SelectedArea(
                relation.handle,
                relation.id,
                relation.members.length,
                area.rings.length,
                summary.segments);

            if (!result.largestComplete.handle.valid ||
                candidate.members > result.largestComplete.members)
                result.largestComplete = candidate;

            if (isFragmented &&
                (!result.largestFragmented.handle.valid ||
                 candidate.members > result.largestFragmented.members))
                result.largestFragmented = candidate;
        }

        if (auto oracle = relation.id in reference)
        {
            ++result.referenceOverlap;

            if (area.state == AreaAssemblyState.complete)
            {
                ++result.referenceCompleteOverlap;
                if (area.outerRingCount != oracle.outer ||
                    area.innerRingCount != oracle.inner)
                    ++result.referenceRingMismatches;
            }
            else
            {
                ++result.referenceAcceptedButNotComplete;
            }
        }
        else if (area.state == AreaAssemblyState.complete)
        {
            ++result.completeNotReference;
        }
    }

    require(result.total > 0, "real workload contains no type=multipolygon Relation");
    require(result.complete > 0, "real workload contains no complete multipolygon");
    require(result.largestComplete.handle.valid, "no real complete multipolygon selected");

    if (reference.length > 0)
    {
        require(result.referenceOverlap > 0, "osmium reference has no overlapping Relation");
        require(
            result.referenceCompleteOverlap > 0,
            "osmium reference has no overlap with structurally complete osm-d area");
        require(
            result.referenceRingMismatches == 0,
            "osmium and osm-d disagree on outer/inner ring counts");
    }

    return result;
}

private bool sameScan(scope ref const MultipolygonScan a, scope ref const MultipolygonScan b)
    @safe pure nothrow @nogc
{
    return
        a.total == b.total &&
        a.complete == b.complete &&
        a.partial == b.partial &&
        a.ambiguous == b.ambiguous &&
        a.invalid == b.invalid &&
        a.completeFragmented == b.completeFragmented &&
        a.completeMultipleOuter == b.completeMultipleOuter &&
        a.completeWithInner == b.completeWithInner &&
        a.rings == b.rings &&
        a.outerRings == b.outerRings &&
        a.innerRings == b.innerRings &&
        a.openChains == b.openChains &&
        a.issues == b.issues &&
        a.vertices == b.vertices &&
        a.segments == b.segments &&
        a.referenceTotal == b.referenceTotal &&
        a.referenceOverlap == b.referenceOverlap &&
        a.referenceCompleteOverlap == b.referenceCompleteOverlap &&
        a.referenceRingMismatches == b.referenceRingMismatches &&
        a.referenceAcceptedButNotComplete == b.referenceAcceptedButNotComplete &&
        a.completeNotReference == b.completeNotReference &&
        a.checksum == b.checksum &&
        a.largestComplete.id == b.largestComplete.id &&
        a.largestComplete.members == b.largestComplete.members &&
        a.largestFragmented.id == b.largestFragmented.id &&
        a.largestFragmented.members == b.largestFragmented.members;
}

private struct AllocationEvidence
{
    ulong allocatedBytes;
    size_t visiblePayloadBytes;
    AreaSummary summary;
}

private AllocationEvidence allocationEvidence(
    OsmStore store,
    OsmHandle handle) @safe
{
    StoreStatus status;
    StoreRelationView relation;
    require(
        store.relation(handle, relation, status),
        "selected allocation Relation became unavailable");

    const before = GC.stats().allocatedInCurrentThread;
    auto area = assembleMultipolygon(store, relation);
    const after = GC.stats().allocatedInCurrentThread;

    AllocationEvidence result;
    result.allocatedBytes = after - before;
    result.visiblePayloadBytes = visibleAreaPayloadBytes(area);
    result.summary = summarizeArea(area);
    return result;
}

private bool addNodeOnce(
    OsmStore store,
    OsmId id,
    ref bool[OsmId] seen,
    ref OwnedDataset data) @safe
{
    if (id in seen)
        return true;

    StoreStatus status;
    StoreNodeView view;
    if (!store.node(id, view, status))
        return false;

    OwnedNode node;
    if (!store.copyNode(view.handle, node, status))
        return false;

    seen[id] = true;
    data.nodes ~= node;
    return true;
}

private bool buildRealAreaSubset(
    OsmStore store,
    SelectedArea selected,
    out OwnedDataset completeData) @safe
{
    StoreStatus status;
    StoreRelationView relationView;
    if (!store.relation(selected.handle, relationView, status))
        return false;

    OwnedRelation relation;
    if (!store.copyRelation(selected.handle, relation, status))
        return false;

    bool[OsmId] seenWays;
    bool[OsmId] seenNodes;

    foreach (ref const member; relation.members)
    {
        if (member.type != ElementType.way)
            return false;

        if (member.id in seenWays)
            continue;

        StoreWayView wayView;
        if (!store.way(member.id, wayView, status))
            return false;

        OwnedWay way;
        if (!store.copyWay(wayView.handle, way, status))
            return false;

        seenWays[member.id] = true;
        completeData.ways ~= way;

        foreach (ref const nodeRef; way.nodes)
            if (!addNodeOnce(store, nodeRef.id, seenNodes, completeData))
                return false;
    }

    completeData.relations ~= relation;
    return completeData.nodes.length > 0 &&
           completeData.ways.length > 0;
}

private bool qualifyRealPartial(
    OsmStore store,
    SelectedArea selected,
    out OsmId missingNodeId,
    out OsmId missingWayId) @safe
{
    OwnedDataset completeData;
    if (!buildRealAreaSubset(store, selected, completeData))
        return false;

    DatasetValidationIssue issue;
    OwnedDatasetIndex index;
    if (!index.build(completeData, issue))
        return false;

    auto completeArea = assembleMultipolygon(
        completeData,
        index,
        completeData.relations[0]);
    if (completeArea.state != AreaAssemblyState.complete)
        return false;

    missingNodeId = completeData.nodes[0].id;
    OwnedDataset missingNode = completeData;
    missingNode.nodes = completeData.nodes[1 .. $].dup;

    OwnedDatasetIndex missingNodeIndex;
    if (!missingNodeIndex.build(missingNode, issue))
        return false;

    auto nodePartial = assembleMultipolygon(
        missingNode,
        missingNodeIndex,
        missingNode.relations[0]);

    if (nodePartial.state != AreaAssemblyState.partial)
        return false;

    bool sawMissingNode;
    foreach (ref const ring; nodePartial.rings)
    {
        foreach (ref const vertex; ring.vertices)
        {
            if (vertex.nodeId == missingNodeId && !vertex.resolved)
                sawMissingNode = true;
        }
    }

    missingWayId = completeData.ways[0].id;
    OwnedDataset missingWay = completeData;
    missingWay.ways = completeData.ways[1 .. $].dup;

    OwnedDatasetIndex missingWayIndex;
    if (!missingWayIndex.build(missingWay, issue))
        return false;

    auto wayPartial = assembleMultipolygon(
        missingWay,
        missingWayIndex,
        missingWay.relations[0]);

    return sawMissingNode &&
           wayPartial.state == AreaAssemblyState.partial;
}

private int run(
    string filename,
    size_t rounds,
    string referenceFilename)
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

    const largestWay = selectLargestCompleteWay(store);
    const largestClosedWay = selectLargestClosedCompleteWay(store);

    CompleteWaySummary waySummary;
    const completeWayP50 = timeCompleteWay(
        store,
        largestWay.handle,
        rounds,
        waySummary);
    require(waySummary.complete, "selected real Way is not complete");
    require(waySummary.nodes == largestWay.nodes, "complete Way lost Node references");

    writefln("complete_way_integrity=pass");
    writefln("complete_way_id=%s", largestWay.id);
    writefln("complete_way_nodes=%s", largestWay.nodes);
    writefln("complete_way_closed=%s", waySummary.closed ? 1 : 0);
    writefln("complete_way_checksum=%s", waySummary.checksum);
    writefln("complete_way_p50_ns=%s", completeWayP50);

    AreaSummary closedWaySummary;
    const closedWayP50 = timeClosedWayArea(
        store,
        largestClosedWay.handle,
        rounds,
        closedWaySummary);
    require(
        closedWaySummary.state == AreaAssemblyState.complete &&
        closedWaySummary.outer == 1 &&
        closedWaySummary.inner == 0 &&
        closedWaySummary.openChains == 0,
        "selected closed Way did not assemble as one outer ring");

    writefln("closed_way_area_integrity=pass");
    writefln("closed_way_id=%s", largestClosedWay.id);
    writefln("closed_way_nodes=%s", largestClosedWay.nodes);
    writefln("closed_way_area_checksum=%s", closedWaySummary.checksum);
    writefln("closed_way_area_p50_ns=%s", closedWayP50);

    auto reference = readReference(referenceFilename);

    const firstScan = scanMultipolygons(store, reference);
    const secondScan = scanMultipolygons(store, reference);
    require(sameScan(firstScan, secondScan), "multipolygon scan is not deterministic");

    writefln("multipolygon_scan_integrity=pass");
    writefln("multipolygon_determinism=pass");
    writefln("multipolygon_total=%s", firstScan.total);
    writefln("multipolygon_complete=%s", firstScan.complete);
    writefln("multipolygon_partial=%s", firstScan.partial);
    writefln("multipolygon_ambiguous=%s", firstScan.ambiguous);
    writefln("multipolygon_invalid=%s", firstScan.invalid);
    writefln("multipolygon_complete_fragmented=%s", firstScan.completeFragmented);
    writefln("multipolygon_complete_multiple_outer=%s", firstScan.completeMultipleOuter);
    writefln("multipolygon_complete_with_inner=%s", firstScan.completeWithInner);
    writefln("multipolygon_rings=%s", firstScan.rings);
    writefln("multipolygon_outer_rings=%s", firstScan.outerRings);
    writefln("multipolygon_inner_rings=%s", firstScan.innerRings);
    writefln("multipolygon_open_chains=%s", firstScan.openChains);
    writefln("multipolygon_issues=%s", firstScan.issues);
    writefln("multipolygon_vertices=%s", firstScan.vertices);
    writefln("multipolygon_segments=%s", firstScan.segments);
    writefln("multipolygon_checksum=%s", firstScan.checksum);

    const timedArea =
        firstScan.largestFragmented.handle.valid
        ? firstScan.largestFragmented
        : firstScan.largestComplete;

    AreaSummary relationAreaSummary;
    const relationAreaP50 = timeRelationArea(
        store,
        timedArea.handle,
        rounds,
        relationAreaSummary);

    require(
        relationAreaSummary.state == AreaAssemblyState.complete,
        "timed real multipolygon is not complete");

    writefln("multipolygon_assembly_integrity=pass");
    writefln("timed_multipolygon_id=%s", timedArea.id);
    writefln("timed_multipolygon_members=%s", timedArea.members);
    writefln("timed_multipolygon_rings=%s", relationAreaSummary.rings);
    writefln("timed_multipolygon_segments=%s", relationAreaSummary.segments);
    writefln("timed_multipolygon_checksum=%s", relationAreaSummary.checksum);
    writefln("multipolygon_assembly_p50_ns=%s", relationAreaP50);

    const allocation = allocationEvidence(store, timedArea.handle);
    require(
        allocation.summary == relationAreaSummary,
        "allocation probe changed assembly semantics");

    writefln("allocation_integrity=pass");
    writefln("multipolygon_allocated_bytes=%s", allocation.allocatedBytes);
    writefln("multipolygon_visible_payload_bytes=%s", allocation.visiblePayloadBytes);

    OsmId missingNodeId;
    OsmId missingWayId;
    require(
        qualifyRealPartial(
            store,
            firstScan.largestComplete,
            missingNodeId,
            missingWayId),
        "real partial-extract qualification failed");

    writefln("real_partial_area_integrity=pass");
    writefln("real_partial_missing_node=%s", missingNodeId);
    writefln("real_partial_missing_way=%s", missingWayId);

    if (reference.length == 0)
    {
        writefln("osmium_reference_integrity=no-reference-areas");
    }
    else
    {
        require(
            firstScan.referenceRingMismatches == 0,
            "independent osmium ring-count comparison failed");
        writefln("osmium_reference_integrity=pass");
    }

    writefln("osmium_reference_total=%s", firstScan.referenceTotal);
    writefln("osmium_reference_overlap=%s", firstScan.referenceOverlap);
    writefln(
        "osmium_reference_complete_overlap=%s",
        firstScan.referenceCompleteOverlap);
    writefln(
        "osmium_reference_ring_mismatches=%s",
        firstScan.referenceRingMismatches);
    writefln(
        "osmium_reference_accepted_but_not_complete=%s",
        firstScan.referenceAcceptedButNotComplete);
    writefln(
        "osm_complete_not_osmium_reference=%s",
        firstScan.completeNotReference);

    writefln("m16_area_qualification=pass");
    return 0;
}

int main(string[] args)
{
    if (args.length < 2 || args.length > 4)
    {
        stderr.writeln(
            "usage: osm-d-bench-area-qualification "
            ~ "<file.osm.pbf> [rounds] [osmium-reference.tsv]");
        return 2;
    }

    size_t rounds = defaultRounds;
    if (args.length >= 3)
        rounds = to!size_t(args[2]);

    if (rounds == 0)
    {
        stderr.writeln("rounds must be > 0");
        return 2;
    }

    const referenceFilename = args.length == 4 ? args[3] : "";

    try
    {
        return run(args[1], rounds, referenceFilename);
    }
    catch (Exception e)
    {
        stderr.writefln("qualification failed: %s", e.msg);
        return 1;
    }
}
