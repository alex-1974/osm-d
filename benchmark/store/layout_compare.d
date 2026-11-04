/**
 * M6 compact-store layout qualification.
 *
 * This benchmark isolates the in-memory representation decision from the direct
 * PBF-to-store construction work tracked by #64. The pinned PBF is first
 * materialized through the common loss-aware reader, then either retained in a
 * straightforward owned reference store or copied into the compact candidate.
 *
 * Both variants use the same packed benchmark-only parent index so reverse
 * navigation memory/work is present in both sides without prematurely choosing
 * the production #63 reverse-index implementation.
 */
module osm.benchmark.store.layout_compare;

import core.memory : GC;
import osm :
    ElementType,
    OsmHandle,
    OsmId,
    OsmStore,
    OwnedDataset,
    OwnedMetadata,
    OwnedNode,
    OwnedRelation,
    OwnedRelationMember,
    OwnedTag,
    OwnedWay,
    OwnedWayNode,
    PbfDocument,
    PbfReadStatus,
    StoreMetadataView,
    StoreElementState,
    StoreNodeView,
    StoreRelationView,
    StoreStatus,
    StoreWayView,
    ownBytes,
    readPbfDocument;

import osm.io.pbf.reader : PbfReadSummary, PbfReader, PbfReaderWorkspace;

import osm.store.compact.store : ManualArray;

import std.algorithm.sorting : sort;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : File, stderr, writefln;
import std.string : startsWith;

private enum rounds = 7;

private struct Timing
{
    long p50;
    long p90;
    ulong checksum;
}

private struct ParentKey
{
    ElementType type;
    OsmId id;
}

private struct ParentEdge
{
    ParentKey key;
    OsmId parent;
}

private struct ParentSpan
{
    uint offset;
    uint length;
}

private bool keyLess(scope ref const ParentKey a, scope ref const ParentKey b)
    @safe pure nothrow @nogc
{
    if (a.type != b.type)
        return cast(ubyte)a.type < cast(ubyte)b.type;
    return a.id < b.id;
}

private bool keyEqual(scope ref const ParentKey a, scope ref const ParentKey b)
    @safe pure nothrow @nogc
{
    return a.type == b.type && a.id == b.id;
}

private ulong hashId(OsmId id) @safe pure nothrow @nogc
{
    ulong x = cast(ulong)id;
    x ^= x >> 30;
    x *= 0xbf58476d1ce4e5b9UL;
    x ^= x >> 27;
    x *= 0x94d049bb133111ebUL;
    x ^= x >> 31;
    return x;
}

private ulong hashKey(ParentKey key) @safe pure nothrow @nogc
{
    return hashId(key.id ^ (cast(long)cast(ubyte)key.type << 57));
}

/**
 * Common packed parent index used on both benchmark sides.
 *
 * This is benchmark infrastructure only. #63 owns the production reverse-index
 * API/layout decision.
 */
private struct PackedParentIndex
{
    ManualArray!ParentKey keys;
    ManualArray!ParentSpan spans;
    ManualArray!OsmId parents;
    ManualArray!uint buckets;

    void build(ref ManualArray!ParentEdge edges) @safe
    {
        if (edges.length == 0)
        {
            buckets.length = 16;
            return;
        }

        sort!((a, b) {
            if (a.key.type != b.key.type)
                return cast(ubyte)a.key.type < cast(ubyte)b.key.type;
            if (a.key.id != b.key.id)
                return a.key.id < b.key.id;
            return a.parent < b.parent;
        })(edges[]);

        size_t begin;
        while (begin < edges.length)
        {
            size_t end = begin + 1;
            while (end < edges.length &&
                   keyEqual(edges[begin].key, edges[end].key))
                ++end;

            assert(keys.length <= uint.max);
            assert(parents.length <= uint.max);
            assert(end - begin <= uint.max);

            keys ~= edges[begin].key;
            const parentOffset = cast(uint)parents.length;

            OsmId previousParent;
            bool hasPrevious;
            foreach (i; begin .. end)
            {
                const parent = edges[i].parent;
                if (hasPrevious && parent == previousParent)
                    continue;
                parents ~= parent;
                previousParent = parent;
                hasPrevious = true;
            }

            spans ~= ParentSpan(
                parentOffset,
                cast(uint)parents.length - parentOffset);

            begin = end;
        }

        size_t capacity = 16;
        while (capacity * 7 < keys.length * 10)
            capacity *= 2;
        buckets.length = capacity;

        foreach (uint i; 0 .. cast(uint)keys.length)
        {
            size_t mask = buckets.length - 1;
            size_t pos = cast(size_t)hashKey(keys[i]) & mask;
            while (buckets[pos] != 0)
                pos = (pos + 1) & mask;
            buckets[pos] = i + 1;
        }
    }

    const(OsmId)[] find(ParentKey key) const @safe nothrow @nogc
    {
        if (buckets.length == 0)
            return null;

        size_t mask = buckets.length - 1;
        size_t pos = cast(size_t)hashKey(key) & mask;

        for (;;)
        {
            const encoded = buckets[pos];
            if (encoded == 0)
                return null;

            const index = encoded - 1;
            if (keyEqual(keys[index], key))
            {
                const span = spans[index];
                return parents[span.offset .. span.offset + span.length];
            }

            pos = (pos + 1) & mask;
        }
    }

    @property size_t logicalBytes() const @safe pure nothrow @nogc
    {
        return keys.length * ParentKey.sizeof +
               spans.length * ParentSpan.sizeof +
               parents.length * OsmId.sizeof +
               buckets.length * uint.sizeof;
    }
}

private struct ParentIndexes
{
    PackedParentIndex nodeWays;
    PackedParentIndex elementRelations;

    void build(scope ref const OwnedDataset data) @safe
    {
        ManualArray!ParentEdge nodeWayEdges;
        ManualArray!ParentEdge relationEdges;

        foreach (ref const way; data.ways)
        {
            foreach (ref const node; way.nodes)
            {
                ParentEdge edge;
                edge.key.type = ElementType.node;
                edge.key.id = node.id;
                edge.parent = way.id;
                nodeWayEdges ~= edge;
            }
        }

        foreach (ref const relation; data.relations)
        {
            foreach (ref const member; relation.members)
            {
                ParentEdge edge;
                edge.key.type = member.type;
                edge.key.id = member.id;
                edge.parent = relation.id;
                relationEdges ~= edge;
            }
        }

        nodeWays.build(nodeWayEdges);
        elementRelations.build(relationEdges);
    }


    void build(OsmStore store) @safe
    {
        ManualArray!ParentEdge nodeWayEdges;
        ManualArray!ParentEdge relationEdges;

        auto ways = store.ways;
        while (!ways.empty)
        {
            auto way = ways.front;
            auto nodes = way.nodes;
            while (!nodes.empty)
            {
                ParentEdge edge;
                edge.key.type = ElementType.node;
                edge.key.id = nodes.front.id;
                edge.parent = way.id;
                nodeWayEdges ~= edge;
                nodes.popFront();
            }
            ways.popFront();
        }

        auto relations = store.relations;
        while (!relations.empty)
        {
            auto relation = relations.front;
            auto members = relation.members;
            while (!members.empty)
            {
                const member = members.front;
                ParentEdge edge;
                edge.key.type = member.type;
                edge.key.id = member.id;
                edge.parent = relation.id;
                relationEdges ~= edge;
                members.popFront();
            }
            relations.popFront();
        }

        nodeWays.build(nodeWayEdges);
        elementRelations.build(relationEdges);
    }

    const(OsmId)[] waysForNode(OsmId id) const @safe nothrow @nogc
    {
        return nodeWays.find(ParentKey(ElementType.node, id));
    }

    const(OsmId)[] relationsFor(ElementType type, OsmId id) const
        @safe nothrow @nogc
    {
        return elementRelations.find(ParentKey(type, id));
    }

    @property size_t logicalBytes() const @safe pure nothrow @nogc
    {
        return nodeWays.logicalBytes + elementRelations.logicalBytes;
    }
}

private final class ReferenceStore
{
    OwnedDataset data;
    uint[OsmId] nodeIndex;
    uint[OsmId] wayIndex;
    uint[OsmId] relationIndex;

    this(OwnedDataset source) @safe
    {
        data = source;
        foreach (i, ref const value; data.nodes)
            nodeIndex[value.id] = cast(uint)i;
        foreach (i, ref const value; data.ways)
            wayIndex[value.id] = cast(uint)i;
        foreach (i, ref const value; data.relations)
            relationIndex[value.id] = cast(uint)i;
    }

    bool find(ElementType type, OsmId id, out uint slot) @safe nothrow
    {
        final switch (type)
        {
            case ElementType.node:
                if (auto p = id in nodeIndex)
                {
                    slot = *p;
                    return true;
                }
                break;
            case ElementType.way:
                if (auto p = id in wayIndex)
                {
                    slot = *p;
                    return true;
                }
                break;
            case ElementType.relation:
                if (auto p = id in relationIndex)
                {
                    slot = *p;
                    return true;
                }
                break;
        }
        slot = 0;
        return false;
    }

    OwnedNode[uint] nodeBaselines;
    OwnedWay[uint] wayBaselines;
    OwnedRelation[uint] relationBaselines;

    void replaceNode(uint slot, scope ref const OwnedNode value) @safe
    {
        if (slot !in nodeBaselines)
            nodeBaselines[slot] = data.nodes[slot].deepCopy();
        data.nodes[slot] = value.deepCopy();
    }

    void replaceWay(uint slot, scope ref const OwnedWay value) @safe
    {
        if (slot !in wayBaselines)
            wayBaselines[slot] = data.ways[slot].deepCopy();
        data.ways[slot] = value.deepCopy();
    }

    void replaceRelation(uint slot, scope ref const OwnedRelation value) @safe
    {
        if (slot !in relationBaselines)
            relationBaselines[slot] = data.relations[slot].deepCopy();
        data.relations[slot] = value.deepCopy();
    }

    void deleteRestoreNode(uint slot) @safe
    {
        const hadBaseline = slot in nodeBaselines;
        if (!hadBaseline)
            nodeBaselines[slot] = data.nodes[slot].deepCopy();

        const id = data.nodes[slot].id;
        require(nodeIndex.remove(id), "reference node delete failed");
        nodeIndex[id] = slot;

        if (!hadBaseline)
            nodeBaselines.remove(slot);
    }

    void deleteRestoreWay(uint slot) @safe
    {
        const hadBaseline = slot in wayBaselines;
        if (!hadBaseline)
            wayBaselines[slot] = data.ways[slot].deepCopy();

        const id = data.ways[slot].id;
        require(wayIndex.remove(id), "reference way delete failed");
        wayIndex[id] = slot;

        if (!hadBaseline)
            wayBaselines.remove(slot);
    }

    void deleteRestoreRelation(uint slot) @safe
    {
        const hadBaseline = slot in relationBaselines;
        if (!hadBaseline)
            relationBaselines[slot] = data.relations[slot].deepCopy();

        const id = data.relations[slot].id;
        require(relationIndex.remove(id), "reference relation delete failed");
        relationIndex[id] = slot;

        if (!hadBaseline)
            relationBaselines.remove(slot);
    }

    void addCreated(scope ref const OwnedNode value) @safe
    {
        const slot = cast(uint)data.nodes.length;
        data.nodes ~= value.deepCopy();
        nodeIndex[value.id] = slot;
    }

    void addCreated(scope ref const OwnedWay value) @safe
    {
        const slot = cast(uint)data.ways.length;
        data.ways ~= value.deepCopy();
        wayIndex[value.id] = slot;
    }

    void addCreated(scope ref const OwnedRelation value) @safe
    {
        const slot = cast(uint)data.relations.length;
        data.relations ~= value.deepCopy();
        relationIndex[value.id] = slot;
    }

    void revertBaselines() @safe
    {
        foreach (slot, ref baseline; nodeBaselines)
            data.nodes[slot] = baseline;
        foreach (slot, ref baseline; wayBaselines)
            data.ways[slot] = baseline;
        foreach (slot, ref baseline; relationBaselines)
            data.relations[slot] = baseline;

        nodeBaselines = null;
        wayBaselines = null;
        relationBaselines = null;
    }

    @property size_t baselineOwnedBytes() const @safe
    {
        size_t result;
        foreach (slot, ref const value; nodeBaselines)
            result += ownedNodeBytes(value);
        foreach (slot, ref const value; wayBaselines)
            result += ownedWayBytes(value);
        foreach (slot, ref const value; relationBaselines)
            result += ownedRelationBytes(value);
        return result;
    }

    @property size_t estimatedOwnedBytes() const @safe pure nothrow @nogc
    {
        return ownedDatasetBytes(data) +
               nodeIndex.length * (OsmId.sizeof + uint.sizeof) +
               wayIndex.length * (OsmId.sizeof + uint.sizeof) +
               relationIndex.length * (OsmId.sizeof + uint.sizeof);
    }
}

private void mix(ref ulong hash, ulong value) @safe pure nothrow @nogc
{
    hash ^= value + 0x9e3779b97f4a7c15UL + (hash << 6) + (hash >> 2);
}

private void mixBytes(ref ulong hash, scope const(ubyte)[] bytes)
    @safe pure nothrow @nogc
{
    mix(hash, bytes.length);
    foreach (b; bytes)
        mix(hash, b);
}

private void mixMetadata(ref ulong hash, scope ref const OwnedMetadata value)
    @safe pure nothrow @nogc
{
    mix(hash, value.hasVersion);
    if (value.hasVersion) mix(hash, cast(ulong)value.versionNumber);
    mix(hash, value.hasTimestamp);
    if (value.hasTimestamp) mix(hash, cast(ulong)value.timestampMilliseconds);
    mix(hash, value.hasChangeset);
    if (value.hasChangeset) mix(hash, cast(ulong)value.changesetId);
    mix(hash, value.hasUserId);
    if (value.hasUserId) mix(hash, cast(ulong)value.userId);
    mix(hash, value.hasUsername);
    if (value.hasUsername) mixBytes(hash, value.username);
    mix(hash, value.hasVisibility);
    if (value.hasVisibility) mix(hash, value.visible);
}

private void mixMetadata(ref ulong hash, scope ref const StoreMetadataView value)
    @safe pure nothrow @nogc
{
    mix(hash, value.hasVersion);
    if (value.hasVersion) mix(hash, cast(ulong)value.versionNumber);
    mix(hash, value.hasTimestamp);
    if (value.hasTimestamp) mix(hash, cast(ulong)value.timestampMilliseconds);
    mix(hash, value.hasChangeset);
    if (value.hasChangeset) mix(hash, cast(ulong)value.changesetId);
    mix(hash, value.hasUserId);
    if (value.hasUserId) mix(hash, cast(ulong)value.userId);
    mix(hash, value.hasUsername);
    if (value.hasUsername) mixBytes(hash, value.username);
    mix(hash, value.hasVisibility);
    if (value.hasVisibility) mix(hash, value.visible);
}

private ulong traverseReference(scope ref const OwnedDataset data)
    @safe pure nothrow @nogc
{
    ulong hash = 0x243f6a8885a308d3UL;

    foreach (ref const node; data.nodes)
    {
        mix(hash, cast(ulong)node.id);
        mix(hash, cast(ulong)node.location.latitudeNanodegrees);
        mix(hash, cast(ulong)node.location.longitudeNanodegrees);
        mixMetadata(hash, node.metadata);
        foreach (ref const tag; node.tags)
        {
            mixBytes(hash, tag.key);
            mixBytes(hash, tag.value);
        }
    }

    foreach (ref const way; data.ways)
    {
        mix(hash, cast(ulong)way.id);
        mixMetadata(hash, way.metadata);
        foreach (ref const tag; way.tags)
        {
            mixBytes(hash, tag.key);
            mixBytes(hash, tag.value);
        }
        foreach (ref const node; way.nodes)
        {
            mix(hash, cast(ulong)node.id);
            mix(hash, node.hasLocation);
            if (node.hasLocation)
            {
                mix(hash, cast(ulong)node.location.latitudeNanodegrees);
                mix(hash, cast(ulong)node.location.longitudeNanodegrees);
            }
        }
    }

    foreach (ref const relation; data.relations)
    {
        mix(hash, cast(ulong)relation.id);
        mixMetadata(hash, relation.metadata);
        foreach (ref const tag; relation.tags)
        {
            mixBytes(hash, tag.key);
            mixBytes(hash, tag.value);
        }
        foreach (ref const member; relation.members)
        {
            mix(hash, cast(ulong)cast(ubyte)member.type);
            mix(hash, cast(ulong)member.id);
            mixBytes(hash, member.role);
        }
    }

    return hash;
}

private ulong traverseCompact(OsmStore store) @safe nothrow @nogc
{
    ulong hash = 0x243f6a8885a308d3UL;

    auto nodes = store.nodes;
    while (!nodes.empty)
    {
        auto node = nodes.front;
        mix(hash, cast(ulong)node.id);
        mix(hash, cast(ulong)node.location.latitudeNanodegrees);
        mix(hash, cast(ulong)node.location.longitudeNanodegrees);
        mixMetadata(hash, node.metadata);

        auto tags = node.tags;
        while (!tags.empty)
        {
            const tag = tags.front;
            mixBytes(hash, tag.key);
            mixBytes(hash, tag.value);
            tags.popFront();
        }
        nodes.popFront();
    }

    auto ways = store.ways;
    while (!ways.empty)
    {
        auto way = ways.front;
        mix(hash, cast(ulong)way.id);
        mixMetadata(hash, way.metadata);

        auto tags = way.tags;
        while (!tags.empty)
        {
            const tag = tags.front;
            mixBytes(hash, tag.key);
            mixBytes(hash, tag.value);
            tags.popFront();
        }

        auto refs = way.nodes;
        while (!refs.empty)
        {
            const node = refs.front;
            mix(hash, cast(ulong)node.id);
            mix(hash, node.hasLocation);
            if (node.hasLocation)
            {
                mix(hash, cast(ulong)node.location.latitudeNanodegrees);
                mix(hash, cast(ulong)node.location.longitudeNanodegrees);
            }
            refs.popFront();
        }
        ways.popFront();
    }

    auto relations = store.relations;
    while (!relations.empty)
    {
        auto relation = relations.front;
        mix(hash, cast(ulong)relation.id);
        mixMetadata(hash, relation.metadata);

        auto tags = relation.tags;
        while (!tags.empty)
        {
            const tag = tags.front;
            mixBytes(hash, tag.key);
            mixBytes(hash, tag.value);
            tags.popFront();
        }

        auto members = relation.members;
        while (!members.empty)
        {
            const member = members.front;
            mix(hash, cast(ulong)cast(ubyte)member.type);
            mix(hash, cast(ulong)member.id);
            mixBytes(hash, member.role);
            members.popFront();
        }
        relations.popFront();
    }

    return hash;
}

private OsmId[] idsOf(scope const(OwnedNode)[] values) @safe
{
    OsmId[] result;
    result.length = values.length;
    foreach (i, ref const value; values)
        result[i] = value.id;
    return result;
}

private OsmId[] idsOf(scope const(OwnedWay)[] values) @safe
{
    OsmId[] result;
    result.length = values.length;
    foreach (i, ref const value; values)
        result[i] = value.id;
    return result;
}

private OsmId[] idsOf(scope const(OwnedRelation)[] values) @safe
{
    OsmId[] result;
    result.length = values.length;
    foreach (i, ref const value; values)
        result[i] = value.id;
    return result;
}

private OsmId[] makeQueries(scope const(OsmId)[] existing, size_t count) @safe
{
    OsmId[] result;
    result.length = count;
    foreach (i; 0 .. count)
    {
        if (i % 10 == 9 || existing.length == 0)
            result[i] = long.min + cast(long)i + 1;
        else
            result[i] = existing[(i * 104729UL) % existing.length];
    }
    return result;
}

private void require(bool condition, string message) @safe
{
    if (!condition)
        throw new Exception(message);
}

private long elapsedNs(void delegate() operation) @trusted
{
    StopWatch sw = StopWatch(AutoStart.yes);
    operation();
    sw.stop();
    return sw.peek.total!"nsecs";
}

private Timing measureLookupReference(
    ReferenceStore store,
    ElementType type,
    scope const(OsmId)[] queries) @safe
{
    long[rounds] samples;
    ulong expected;

    foreach (round; 0 .. rounds)
    {
        ulong hash;
        samples[round] = elapsedNs(() {
            uint slot;
            foreach (id; queries)
            {
                if (store.find(type, id, slot))
                {
                    mix(hash, cast(ulong)id);
                    mix(hash, slot);
                }
            }
        });
        if (round == 0)
            expected = hash;
        else
            assert(hash == expected);
    }

    sort(samples[]);
    return Timing(samples[rounds / 2], samples[rounds - 1], expected);
}

private Timing measureLookupCompact(
    OsmStore store,
    ElementType type,
    scope const(OsmId)[] queries) @safe
{
    long[rounds] samples;
    ulong expected;

    foreach (round; 0 .. rounds)
    {
        ulong hash;
        samples[round] = elapsedNs(() {
            OsmHandle handle;
            foreach (id; queries)
            {
                if (store.find(type, id, handle))
                {
                    mix(hash, cast(ulong)id);
                    mix(hash, handle.valid);
                }
            }
        });
        if (round == 0)
            expected = hash;
        else
            assert(hash == expected);
    }

    sort(samples[]);
    return Timing(samples[rounds / 2], samples[rounds - 1], expected);
}

private ulong parentToken(OsmId id) @safe pure nothrow @nogc
{
    return hashId(id) ^ 0x9e3779b97f4a7c15UL;
}

private Timing measureNodeParentsReference(
    scope ref const ParentIndexes parents,
    scope const(OsmId)[] queries) @safe
{
    long[rounds] samples;
    ulong expected;

    foreach (round; 0 .. rounds)
    {
        ulong hash;
        samples[round] = elapsedNs(() {
            foreach (id; queries)
            {
                const values = parents.waysForNode(id);
                ulong fold;
                foreach (parent; values)
                    fold ^= parentToken(parent);
                mix(hash, values.length);
                mix(hash, fold);
            }
        });
        if (round == 0)
            expected = hash;
        else
            assert(hash == expected);
    }

    sort(samples[]);
    return Timing(samples[rounds / 2], samples[rounds - 1], expected);
}

private Timing measureNodeParentsCompact(
    OsmStore store,
    scope const(OsmId)[] queries) @safe
{
    long[rounds] samples;
    ulong expected;

    foreach (round; 0 .. rounds)
    {
        ulong hash;
        samples[round] = elapsedNs(() {
            foreach (id; queries)
            {
                auto values = store.parentWays(id);
                size_t count;
                ulong fold;
                while (!values.empty)
                {
                    fold ^= parentToken(values.front.id);
                    ++count;
                    values.popFront();
                }
                mix(hash, count);
                mix(hash, fold);
            }
        });
        if (round == 0)
            expected = hash;
        else
            assert(hash == expected);
    }

    sort(samples[]);
    return Timing(samples[rounds / 2], samples[rounds - 1], expected);
}

private Timing measureRelationParentsReference(
    scope ref const ParentIndexes parents,
    scope const(ParentKey)[] queries) @safe
{
    long[rounds] samples;
    ulong expected;

    foreach (round; 0 .. rounds)
    {
        ulong hash;
        samples[round] = elapsedNs(() {
            foreach (key; queries)
            {
                const values = parents.relationsFor(key.type, key.id);
                ulong fold;
                foreach (parent; values)
                    fold ^= parentToken(parent);
                mix(hash, values.length);
                mix(hash, fold);
            }
        });
        if (round == 0)
            expected = hash;
        else
            assert(hash == expected);
    }

    sort(samples[]);
    return Timing(samples[rounds / 2], samples[rounds - 1], expected);
}

private Timing measureRelationParentsCompact(
    OsmStore store,
    scope const(ParentKey)[] queries) @safe
{
    long[rounds] samples;
    ulong expected;

    foreach (round; 0 .. rounds)
    {
        ulong hash;
        samples[round] = elapsedNs(() {
            foreach (key; queries)
            {
                auto values = store.parentRelations(key.type, key.id);
                size_t count;
                ulong fold;
                while (!values.empty)
                {
                    fold ^= parentToken(values.front.id);
                    ++count;
                    values.popFront();
                }
                mix(hash, count);
                mix(hash, fold);
            }
        });
        if (round == 0)
            expected = hash;
        else
            assert(hash == expected);
    }

    sort(samples[]);
    return Timing(samples[rounds / 2], samples[rounds - 1], expected);
}

private ParentKey[] makeRelationParentQueries(
    scope const(OwnedDataset) data,
    size_t count) @safe
{
    ParentKey[] population;
    population.length =
        data.nodes.length + data.ways.length + data.relations.length;

    size_t at;
    foreach (ref const value; data.nodes)
        population[at++] = ParentKey(ElementType.node, value.id);
    foreach (ref const value; data.ways)
        population[at++] = ParentKey(ElementType.way, value.id);
    foreach (ref const value; data.relations)
        population[at++] = ParentKey(ElementType.relation, value.id);

    ParentKey[] result;
    result.length = count;
    foreach (i; 0 .. count)
    {
        if (i % 10 == 9 || population.length == 0)
            result[i] = ParentKey(ElementType.node, long.min + cast(long)i + 11);
        else
            result[i] = population[(i * 65537UL) % population.length];
    }
    return result;
}

private Timing measureTraversalReference(scope ref const OwnedDataset data) @safe
{
    long[rounds] samples;
    ulong expected;
    foreach (round; 0 .. rounds)
    {
        ulong hash;
        samples[round] = elapsedNs(() { hash = traverseReference(data); });
        if (round == 0) expected = hash; else assert(hash == expected);
    }
    sort(samples[]);
    return Timing(samples[rounds / 2], samples[rounds - 1], expected);
}

private Timing measureTraversalCompact(OsmStore store) @safe
{
    long[rounds] samples;
    ulong expected;
    foreach (round; 0 .. rounds)
    {
        ulong hash;
        samples[round] = elapsedNs(() { hash = traverseCompact(store); });
        if (round == 0) expected = hash; else assert(hash == expected);
    }
    sort(samples[]);
    return Timing(samples[rounds / 2], samples[rounds - 1], expected);
}

private size_t ownedMetadataBytes(scope ref const OwnedMetadata value)
    @safe pure nothrow @nogc
{
    return OwnedMetadata.sizeof +
        (value.hasUsername ? value.username.length : 0);
}

private size_t ownedTagBytes(scope ref const OwnedTag value)
    @safe pure nothrow @nogc
{
    return OwnedTag.sizeof + value.key.length + value.value.length;
}

private size_t ownedNodeBytes(scope ref const OwnedNode value)
    @safe pure nothrow @nogc
{
    size_t result = OwnedNode.sizeof + ownedMetadataBytes(value.metadata);
    foreach (ref const tag; value.tags)
        result += ownedTagBytes(tag);
    return result;
}

private size_t ownedWayBytes(scope ref const OwnedWay value)
    @safe pure nothrow @nogc
{
    size_t result = OwnedWay.sizeof + ownedMetadataBytes(value.metadata);
    result += value.nodes.length * OwnedWayNode.sizeof;
    foreach (ref const tag; value.tags)
        result += ownedTagBytes(tag);
    return result;
}

private size_t ownedRelationBytes(scope ref const OwnedRelation value)
    @safe pure nothrow @nogc
{
    size_t result =
        OwnedRelation.sizeof + ownedMetadataBytes(value.metadata);
    foreach (ref const tag; value.tags)
        result += ownedTagBytes(tag);
    foreach (ref const member; value.members)
        result += OwnedRelationMember.sizeof + member.role.length;
    return result;
}

private size_t ownedDatasetBytes(scope ref const OwnedDataset data)
    @safe pure nothrow @nogc
{
    size_t result =
        data.nodes.length * OwnedNode.sizeof +
        data.ways.length * OwnedWay.sizeof +
        data.relations.length * OwnedRelation.sizeof;

    foreach (ref const node; data.nodes)
    {
        result += ownedMetadataBytes(node.metadata);
        result += node.tags.length * OwnedTag.sizeof;
        foreach (ref const tag; node.tags)
            result += tag.key.length + tag.value.length;
    }

    foreach (ref const way; data.ways)
    {
        result += ownedMetadataBytes(way.metadata);
        result += way.tags.length * OwnedTag.sizeof;
        foreach (ref const tag; way.tags)
            result += tag.key.length + tag.value.length;
        result += way.nodes.length * OwnedWayNode.sizeof;
    }

    foreach (ref const relation; data.relations)
    {
        result += ownedMetadataBytes(relation.metadata);
        result += relation.tags.length * OwnedTag.sizeof;
        foreach (ref const tag; relation.tags)
            result += tag.key.length + tag.value.length;
        result += relation.members.length * OwnedRelationMember.sizeof;
        foreach (ref const member; relation.members)
            result += member.role.length;
    }

    return result;
}

private size_t currentRssKiB() @trusted
{
    auto status = File("/proc/self/status", "r");
    foreach (line; status.byLine())
    {
        if (!line.startsWith("VmRSS:"))
            continue;

        size_t value;
        import std.conv : to;
        import std.string : split;
        auto parts = line.split();
        if (parts.length >= 2)
            value = parts[1].to!size_t;
        return value;
    }
    return 0;
}

private size_t peakRssKiB() @trusted
{
    auto status = File("/proc/self/status", "r");
    foreach (line; status.byLine())
    {
        if (!line.startsWith("VmHWM:"))
            continue;

        import std.conv : to;
        import std.string : split;
        auto parts = line.split();
        if (parts.length >= 2)
            return parts[1].to!size_t;
    }
    return 0;
}

private void minimizeGc() @safe
{
    GC.collect();
    GC.minimize();
}

private void freeGcArray(T)(ref T[] value) @trusted
{
    if (value.ptr !is null)
        GC.free(cast(void*)value.ptr);
    value = null;
}

private void freeOwnedBytes(ref immutable(ubyte)[] value) @trusted
{
    if (value.ptr !is null)
        GC.free(cast(void*)value.ptr);
    value = null;
}

private void releaseMetadataBytes(ref OwnedMetadata metadata) @trusted
{
    if (metadata.hasUsername)
        freeOwnedBytes(metadata.username);
}

private void releaseDataset(ref OwnedDataset data) @trusted
{
    foreach (ref node; data.nodes)
    {
        releaseMetadataBytes(node.metadata);
        foreach (ref tag; node.tags)
        {
            freeOwnedBytes(tag.key);
            freeOwnedBytes(tag.value);
        }
        freeGcArray(node.tags);
    }

    foreach (ref way; data.ways)
    {
        releaseMetadataBytes(way.metadata);
        foreach (ref tag; way.tags)
        {
            freeOwnedBytes(tag.key);
            freeOwnedBytes(tag.value);
        }
        freeGcArray(way.tags);
        freeGcArray(way.nodes);
    }

    foreach (ref relation; data.relations)
    {
        releaseMetadataBytes(relation.metadata);
        foreach (ref tag; relation.tags)
        {
            freeOwnedBytes(tag.key);
            freeOwnedBytes(tag.value);
        }
        freeGcArray(relation.tags);

        foreach (ref member; relation.members)
            freeOwnedBytes(member.role);
        freeGcArray(relation.members);
    }

    freeGcArray(data.nodes);
    freeGcArray(data.ways);
    freeGcArray(data.relations);
}

private void releaseDocumentEnvelope(ref PbfDocument document) @trusted
{
    foreach (ref feature; document.header.requiredFeatures)
        freeOwnedBytes(feature);
    freeGcArray(document.header.requiredFeatures);

    foreach (ref feature; document.header.optionalFeatures)
        freeOwnedBytes(feature);
    freeGcArray(document.header.optionalFeatures);

    if (document.header.hasWritingProgram)
        freeOwnedBytes(document.header.writingProgram);
    if (document.header.hasSource)
        freeOwnedBytes(document.header.source);
    if (document.header.hasReplicationBaseUrl)
        freeOwnedBytes(document.header.replicationBaseUrl);

    freeOwnedBytes(document.preservation.source.bytes);
    document.header = typeof(document.header).init;
    document.preservation = typeof(document.preservation).init;
}

private void releaseDocument(ref PbfDocument document) @trusted
{
    releaseDataset(document.data);
    releaseDocumentEnvelope(document);
    document = PbfDocument.init;
}


private struct DirectStoreHandler
{
    OsmStore store;
    StoreStatus status;
    bool failed;

    void node(Node)(scope ref Node value) @safe nothrow @nogc
    {
        if (!failed && !store.addBorrowedNode(value, status))
            failed = true;
    }

    void way(Way)(scope ref Way value) @safe nothrow @nogc
    {
        if (!failed && !store.addBorrowedWay(value, status))
            failed = true;
    }

    void relation(Relation)(scope ref Relation value) @safe nothrow @nogc
    {
        if (!failed && !store.addBorrowedRelation(value, status))
            failed = true;
    }
}

private long measureDirectStoreBuild(
    scope const(ubyte)[] input,
    out OsmStore store,
    out PbfReadSummary summary,
    out StoreStatus storeStatus) @safe
{
    store = new OsmStore();
    PbfReader reader;
    PbfReaderWorkspace workspace;
    PbfReadStatus readStatus;
    DirectStoreHandler handler;
    handler.store = store;

    const elapsed = elapsedNs(() {
        if (!reader.read(input, workspace, handler, summary, readStatus))
            throw new Exception("direct PBF reader failed");
    });

    storeStatus = handler.status;
    if (handler.failed)
        throw new Exception("borrowed store ingest failed");

    // Reader scratch is not retained by the store.
    workspace = PbfReaderWorkspace.init;
    return elapsed;
}

private long measureSourceDecode(
    scope const(ubyte)[] input,
    out PbfDocument document) @safe
{
    PbfReadStatus status;
    long elapsed = elapsedNs(() {
        if (!readPbfDocument(input, document, status))
        {
            stderr.writefln(
                "PBF document read failed: %s block=%s offset=%s",
                status.error,
                status.blockSequence,
                status.blockOffset);
            assert(0, "PBF document read failed");
        }
    });
    return elapsed;
}

private void printTiming(string prefix, Timing value)
{
    writefln("%s_p50_ns=%s", prefix, value.p50);
    writefln("%s_p90_ns=%s", prefix, value.p90);
    writefln("%s_checksum=%s", prefix, value.checksum);
}


private struct EditSelection
{
    OsmId[] nodeTags;
    OsmId[] wayTags;
    OsmId[] relationTags;
    OsmId[] nodeCoordinates;
    OsmId[] wayReferences;
    OsmId[] relationMembers;
    OsmId[] deleteNodes;
    OsmId[] deleteWays;
    OsmId[] deleteRelations;
}

private struct EditMetrics
{
    long editNs;
    long revertNs;
    long parentUpdateNs;
    ulong editChecksum;
    ulong revertChecksum;
    size_t postEditOwnedBytes;
    size_t postRevertOwnedBytes;
}

private struct RemapMetrics
{
    long elapsedNs;
    ulong checksum;
}

private EditSelection makeEditSelection(scope ref const OwnedDataset data) @safe
{
    EditSelection result;

    foreach (ref const node; data.nodes)
    {
        if (result.nodeTags.length < 3_000)
            result.nodeTags ~= node.id;
        if (result.nodeCoordinates.length < 2_000)
            result.nodeCoordinates ~= node.id;
        if (result.deleteNodes.length < 200)
            result.deleteNodes ~= node.id;
    }

    foreach (ref const way; data.ways)
    {
        if (result.wayTags.length < 800)
            result.wayTags ~= way.id;
        if (result.wayReferences.length < 1_500 && way.nodes.length >= 2)
            result.wayReferences ~= way.id;
        if (result.deleteWays.length < 200)
            result.deleteWays ~= way.id;
    }

    foreach (ref const relation; data.relations)
    {
        if (result.relationTags.length < 200)
            result.relationTags ~= relation.id;
        if (result.relationMembers.length < 500 &&
            relation.members.length >= 2)
            result.relationMembers ~= relation.id;
        if (result.deleteRelations.length < 100)
            result.deleteRelations ~= relation.id;
    }

    assert(result.nodeTags.length == 3_000);
    assert(result.wayTags.length == 800);
    assert(result.relationTags.length == 200);
    assert(result.nodeCoordinates.length == 2_000);
    assert(result.wayReferences.length == 1_500);
    assert(result.relationMembers.length == 500);
    assert(result.deleteNodes.length == 200);
    assert(result.deleteWays.length == 200);
    assert(result.deleteRelations.length == 100);
    return result;
}


private EditSelection makeEditSelection(OsmStore store) @safe
{
    EditSelection result;

    auto nodes = store.nodes;
    while (!nodes.empty)
    {
        const node = nodes.front;
        if (result.nodeTags.length < 3_000)
            result.nodeTags ~= node.id;
        if (result.nodeCoordinates.length < 2_000)
            result.nodeCoordinates ~= node.id;
        if (result.deleteNodes.length < 200)
            result.deleteNodes ~= node.id;
        nodes.popFront();
    }

    auto ways = store.ways;
    while (!ways.empty)
    {
        const way = ways.front;
        if (result.wayTags.length < 800)
            result.wayTags ~= way.id;
        if (result.wayReferences.length < 1_500 &&
            way.nodes.length >= 2)
            result.wayReferences ~= way.id;
        if (result.deleteWays.length < 200)
            result.deleteWays ~= way.id;
        ways.popFront();
    }

    auto relations = store.relations;
    while (!relations.empty)
    {
        const relation = relations.front;
        if (result.relationTags.length < 200)
            result.relationTags ~= relation.id;
        if (result.relationMembers.length < 500 &&
            relation.members.length >= 2)
            result.relationMembers ~= relation.id;
        if (result.deleteRelations.length < 100)
            result.deleteRelations ~= relation.id;
        relations.popFront();
    }

    assert(result.nodeTags.length == 3_000);
    assert(result.wayTags.length == 800);
    assert(result.relationTags.length == 200);
    assert(result.nodeCoordinates.length == 2_000);
    assert(result.wayReferences.length == 1_500);
    assert(result.relationMembers.length == 500);
    assert(result.deleteNodes.length == 200);
    assert(result.deleteWays.length == 200);
    assert(result.deleteRelations.length == 100);
    return result;
}

private void setBenchmarkTag(
    ref OwnedTag[] tags,
    immutable(ubyte)[] key,
    immutable(ubyte)[] value) @safe
{
    foreach (ref tag; tags)
    {
        if (tag.key == key)
        {
            tag.value = value;
            return;
        }
    }
    tags ~= OwnedTag(key, value);
}

private void editNodeCoordinate(ref OwnedNode value) @safe pure nothrow @nogc
{
    value.location = typeof(value.location)(
        value.location.latitudeNanodegrees + 1,
        value.location.longitudeNanodegrees - 1);
}

private void editWayReferences(ref OwnedWay value) @safe pure nothrow @nogc
{
    assert(value.nodes.length >= 2);
    auto first = value.nodes[0];
    value.nodes[0] = value.nodes[1];
    value.nodes[1] = first;
}

private void editRelationMembers(ref OwnedRelation value)
    @safe pure nothrow @nogc
{
    assert(value.members.length >= 2);
    auto first = value.members[0];
    value.members[0] = value.members[1];
    value.members[1] = first;
}

private OwnedNode[] makeCreatedNodes() @safe
{
    OwnedNode[] result;
    result.length = 800;
    foreach (i, ref value; result)
    {
        value.id = -1 - cast(long)i;
        value.location = typeof(value.location)(
            48_000_000_000L + cast(long)i,
            16_000_000_000L + cast(long)i);
    }
    return result;
}

private OwnedWay[] makeCreatedWays() @safe
{
    OwnedWay[] result;
    result.length = 150;
    foreach (i, ref value; result)
    {
        value.id = -1_001 - cast(long)i;

        OwnedWayNode a;
        a.id = -1 - cast(long)((i * 2) % 800);
        OwnedWayNode b;
        b.id = -1 - cast(long)((i * 2 + 1) % 800);
        value.nodes = [a, b];
    }
    return result;
}

private OwnedRelation[] makeCreatedRelations() @safe
{
    OwnedRelation[] result;
    result.length = 50;
    foreach (i, ref value; result)
    {
        value.id = -2_001 - cast(long)i;

        OwnedRelationMember way;
        way.type = ElementType.way;
        way.id = -1_001 - cast(long)(i % 150);

        OwnedRelationMember node;
        node.type = ElementType.node;
        node.id = -1 - cast(long)(i % 800);

        value.members = [way, node];
    }
    return result;
}

private struct NodeOp
{
    OsmId id;
    OsmHandle handle;
    uint slot;
    OwnedNode original;
    OwnedNode value;
}

private struct WayOp
{
    OsmId id;
    OsmHandle handle;
    uint slot;
    OwnedWay original;
    OwnedWay value;
}

private struct RelationOp
{
    OsmId id;
    OsmHandle handle;
    uint slot;
    OwnedRelation original;
    OwnedRelation value;
}

private uint referenceSlot(
    ReferenceStore store,
    ElementType type,
    OsmId id) @safe
{
    uint slot;
    require(store.find(type, id, slot), "reference lookup failed");
    return slot;
}

private OsmHandle compactHandle(OsmStore store, ElementType type, OsmId id)
    @safe
{
    OsmHandle handle;
    require(store.find(type, id, handle), "compact lookup failed");
    return handle;
}

private EditMetrics runReferenceEdits(
    ReferenceStore store,
    scope ref const EditSelection selection,
    ulong originalChecksum,
    size_t parentBytes) @safe
{
    auto key = ownBytes(cast(const(ubyte)[])"osm-d:layout-benchmark");
    auto valueBytes = ownBytes(cast(const(ubyte)[])"edited");

    NodeOp[] nodeTagOps;
    foreach (id; selection.nodeTags)
    {
        const slot = referenceSlot(store, ElementType.node, id);
        NodeOp op;
        op.id = id;
        op.slot = slot;
        op.original = store.data.nodes[slot].deepCopy();
        op.value = op.original.deepCopy();
        setBenchmarkTag(op.value.tags, key, valueBytes);
        nodeTagOps ~= op;
    }

    WayOp[] wayTagOps;
    foreach (id; selection.wayTags)
    {
        const slot = referenceSlot(store, ElementType.way, id);
        WayOp op;
        op.id = id;
        op.slot = slot;
        op.original = store.data.ways[slot].deepCopy();
        op.value = op.original.deepCopy();
        setBenchmarkTag(op.value.tags, key, valueBytes);
        wayTagOps ~= op;
    }

    RelationOp[] relationTagOps;
    foreach (id; selection.relationTags)
    {
        const slot = referenceSlot(store, ElementType.relation, id);
        RelationOp op;
        op.id = id;
        op.slot = slot;
        op.original = store.data.relations[slot].deepCopy();
        op.value = op.original.deepCopy();
        setBenchmarkTag(op.value.tags, key, valueBytes);
        relationTagOps ~= op;
    }

    NodeOp[] coordinateOps;
    foreach (id; selection.nodeCoordinates)
    {
        const slot = referenceSlot(store, ElementType.node, id);
        NodeOp op;
        op.id = id;
        op.slot = slot;
        op.original = store.data.nodes[slot].deepCopy();
        op.value = op.original.deepCopy();
        editNodeCoordinate(op.value);
        coordinateOps ~= op;
    }

    WayOp[] referenceOps;
    foreach (id; selection.wayReferences)
    {
        const slot = referenceSlot(store, ElementType.way, id);
        WayOp op;
        op.id = id;
        op.slot = slot;
        op.original = store.data.ways[slot].deepCopy();
        op.value = op.original.deepCopy();
        editWayReferences(op.value);
        referenceOps ~= op;
    }

    RelationOp[] memberOps;
    foreach (id; selection.relationMembers)
    {
        const slot = referenceSlot(store, ElementType.relation, id);
        RelationOp op;
        op.id = id;
        op.slot = slot;
        op.original = store.data.relations[slot].deepCopy();
        op.value = op.original.deepCopy();
        editRelationMembers(op.value);
        memberOps ~= op;
    }

    auto createdNodes = makeCreatedNodes();
    auto createdWays = makeCreatedWays();
    auto createdRelations = makeCreatedRelations();

    uint[] deleteNodeSlots;
    foreach (id; selection.deleteNodes)
        deleteNodeSlots ~= referenceSlot(store, ElementType.node, id);
    uint[] deleteWaySlots;
    foreach (id; selection.deleteWays)
        deleteWaySlots ~= referenceSlot(store, ElementType.way, id);
    uint[] deleteRelationSlots;
    foreach (id; selection.deleteRelations)
        deleteRelationSlots ~= referenceSlot(store, ElementType.relation, id);

    const originalNodeLength = store.data.nodes.length;
    const originalWayLength = store.data.ways.length;
    const originalRelationLength = store.data.relations.length;

    EditMetrics metrics;
    metrics.editNs = elapsedNs(() {
        foreach (ref op; nodeTagOps)
            store.replaceNode(op.slot, op.value);
        foreach (ref op; wayTagOps)
            store.replaceWay(op.slot, op.value);
        foreach (ref op; relationTagOps)
            store.replaceRelation(op.slot, op.value);

        foreach (ref op; coordinateOps)
            store.replaceNode(op.slot, op.value);
        foreach (ref op; referenceOps)
            store.replaceWay(op.slot, op.value);
        foreach (ref op; memberOps)
            store.replaceRelation(op.slot, op.value);

        foreach (ref created; createdNodes)
            store.addCreated(created);
        foreach (ref created; createdWays)
            store.addCreated(created);
        foreach (ref created; createdRelations)
            store.addCreated(created);

        foreach (slot; deleteNodeSlots)
            store.deleteRestoreNode(slot);
        foreach (slot; deleteWaySlots)
            store.deleteRestoreWay(slot);
        foreach (slot; deleteRelationSlots)
            store.deleteRestoreRelation(slot);
    });

    metrics.editChecksum = traverseReference(store.data);
    metrics.postEditOwnedBytes =
        store.estimatedOwnedBytes + store.baselineOwnedBytes + parentBytes;

    ParentIndexes editedParents;
    metrics.parentUpdateNs =
        elapsedNs(() { editedParents.build(store.data); });

    metrics.revertNs = elapsedNs(() {
        store.revertBaselines();

        foreach (ref created; createdRelations)
            require(store.relationIndex.remove(created.id), "reference created relation revert failed");
        foreach (ref created; createdWays)
            require(store.wayIndex.remove(created.id), "reference created way revert failed");
        foreach (ref created; createdNodes)
            require(store.nodeIndex.remove(created.id), "reference created node revert failed");

        store.data.relations.length = originalRelationLength;
        store.data.ways.length = originalWayLength;
        store.data.nodes.length = originalNodeLength;
    });

    metrics.revertChecksum = traverseReference(store.data);
    assert(metrics.revertChecksum == originalChecksum);
    metrics.postRevertOwnedBytes =
        store.estimatedOwnedBytes + parentBytes;
    return metrics;
}

private EditMetrics runCompactEdits(
    OsmStore store,
    scope ref const EditSelection selection,
    ulong originalChecksum,
    size_t parentBytes) @safe
{
    auto key = ownBytes(cast(const(ubyte)[])"osm-d:layout-benchmark");
    auto valueBytes = ownBytes(cast(const(ubyte)[])"edited");
    StoreStatus status;

    NodeOp[] nodeTagOps;
    foreach (id; selection.nodeTags)
    {
        NodeOp op;
        op.id = id;
        op.handle = compactHandle(store, ElementType.node, id);
        require(store.copyNode(op.handle, op.value, status), "compact node copy failed");
        setBenchmarkTag(op.value.tags, key, valueBytes);
        nodeTagOps ~= op;
    }

    WayOp[] wayTagOps;
    foreach (id; selection.wayTags)
    {
        WayOp op;
        op.id = id;
        op.handle = compactHandle(store, ElementType.way, id);
        require(store.copyWay(op.handle, op.value, status), "compact way copy failed");
        setBenchmarkTag(op.value.tags, key, valueBytes);
        wayTagOps ~= op;
    }

    RelationOp[] relationTagOps;
    foreach (id; selection.relationTags)
    {
        RelationOp op;
        op.id = id;
        op.handle = compactHandle(store, ElementType.relation, id);
        require(store.copyRelation(op.handle, op.value, status), "compact relation copy failed");
        setBenchmarkTag(op.value.tags, key, valueBytes);
        relationTagOps ~= op;
    }

    NodeOp[] coordinateOps;
    foreach (id; selection.nodeCoordinates)
    {
        NodeOp op;
        op.id = id;
        op.handle = compactHandle(store, ElementType.node, id);
        require(store.copyNode(op.handle, op.value, status), "compact node copy failed");
        editNodeCoordinate(op.value);
        coordinateOps ~= op;
    }

    WayOp[] referenceOps;
    foreach (id; selection.wayReferences)
    {
        WayOp op;
        op.id = id;
        op.handle = compactHandle(store, ElementType.way, id);
        require(store.copyWay(op.handle, op.value, status), "compact way copy failed");
        editWayReferences(op.value);
        referenceOps ~= op;
    }

    RelationOp[] memberOps;
    foreach (id; selection.relationMembers)
    {
        RelationOp op;
        op.id = id;
        op.handle = compactHandle(store, ElementType.relation, id);
        require(store.copyRelation(op.handle, op.value, status), "compact relation copy failed");
        editRelationMembers(op.value);
        memberOps ~= op;
    }

    auto createdNodes = makeCreatedNodes();
    auto createdWays = makeCreatedWays();
    auto createdRelations = makeCreatedRelations();

    OsmHandle[] deleteNodeHandles;
    foreach (id; selection.deleteNodes)
        deleteNodeHandles ~= compactHandle(store, ElementType.node, id);
    OsmHandle[] deleteWayHandles;
    foreach (id; selection.deleteWays)
        deleteWayHandles ~= compactHandle(store, ElementType.way, id);
    OsmHandle[] deleteRelationHandles;
    foreach (id; selection.deleteRelations)
        deleteRelationHandles ~= compactHandle(store, ElementType.relation, id);

    OsmHandle[] createdNodeHandles;
    OsmHandle[] createdWayHandles;
    OsmHandle[] createdRelationHandles;

    EditMetrics metrics;
    metrics.editNs = elapsedNs(() {
        foreach (ref op; nodeTagOps)
            require(store.replace(op.handle, op.value, status), "compact replace failed");
        foreach (ref op; wayTagOps)
            require(store.replace(op.handle, op.value, status), "compact replace failed");
        foreach (ref op; relationTagOps)
            require(store.replace(op.handle, op.value, status), "compact replace failed");

        foreach (ref op; coordinateOps)
            require(store.replace(op.handle, op.value, status), "compact replace failed");
        foreach (ref op; referenceOps)
            require(store.replace(op.handle, op.value, status), "compact replace failed");
        foreach (ref op; memberOps)
            require(store.replace(op.handle, op.value, status), "compact replace failed");

        foreach (ref created; createdNodes)
        {
            OsmHandle handle;
            require(store.add(created, handle, status), "compact create failed");
            createdNodeHandles ~= handle;
        }
        foreach (ref created; createdWays)
        {
            OsmHandle handle;
            require(store.add(created, handle, status), "compact create failed");
            createdWayHandles ~= handle;
        }
        foreach (ref created; createdRelations)
        {
            OsmHandle handle;
            require(store.add(created, handle, status), "compact create failed");
            createdRelationHandles ~= handle;
        }

        foreach (handle; deleteNodeHandles)
        {
            require(store.remove(handle, status), "compact delete failed");
            require(store.restore(handle, status), "compact restore failed");
        }
        foreach (handle; deleteWayHandles)
        {
            require(store.remove(handle, status), "compact delete failed");
            require(store.restore(handle, status), "compact restore failed");
        }
        foreach (handle; deleteRelationHandles)
        {
            require(store.remove(handle, status), "compact delete failed");
            require(store.restore(handle, status), "compact restore failed");
        }
    });

    metrics.editChecksum = traverseCompact(store);
    metrics.postEditOwnedBytes = store.memoryUsage.totalOwnedBytes;

    // Production parent indexes are updated inside each mutation above.
    metrics.parentUpdateNs = 0;

    metrics.revertNs = elapsedNs(() {
        foreach (ref op; relationTagOps)
            require(store.revert(op.handle, status), "compact revert failed");
        foreach (ref op; memberOps)
            require(store.revert(op.handle, status), "compact revert failed");
        foreach (ref op; wayTagOps)
            require(store.revert(op.handle, status), "compact revert failed");
        foreach (ref op; referenceOps)
            require(store.revert(op.handle, status), "compact revert failed");
        foreach (ref op; nodeTagOps)
            require(store.revert(op.handle, status), "compact revert failed");
        foreach (ref op; coordinateOps)
            require(store.revert(op.handle, status), "compact revert failed");

        foreach_reverse (handle; createdRelationHandles)
            require(store.revert(handle, status), "compact created revert failed");
        foreach_reverse (handle; createdWayHandles)
            require(store.revert(handle, status), "compact created revert failed");
        foreach_reverse (handle; createdNodeHandles)
            require(store.revert(handle, status), "compact created revert failed");
    });

    metrics.revertChecksum = traverseCompact(store);
    assert(metrics.revertChecksum == originalChecksum);
    metrics.postRevertOwnedBytes = store.memoryUsage.totalOwnedBytes;
    return metrics;
}

private RemapMetrics runReferenceRemap() @safe
{
    OwnedDataset data;

    OwnedNode node;
    node.id = -1;
    node.location = typeof(node.location)(1, 2);
    data.nodes ~= node;

    OwnedWay way;
    way.id = -2;
    way.nodes ~= OwnedWayNode(-1, false, typeof(node.location).init);
    data.ways ~= way;

    OwnedRelation relation;
    relation.id = -3;
    OwnedRelationMember wayMember;
    wayMember.type = ElementType.way;
    wayMember.id = -2;
    OwnedRelationMember nodeMember;
    nodeMember.type = ElementType.node;
    nodeMember.id = -1;
    relation.members = [wayMember, nodeMember];
    data.relations ~= relation;

    auto store = new ReferenceStore(data);

    RemapMetrics result;
    result.elapsedNs = elapsedNs(() {
        require(store.nodeIndex.remove(-1), "reference node remap delete failed");
        store.data.nodes[0].id = 101;
        store.data.nodes[0].metadata.hasVersion = true;
        store.data.nodes[0].metadata.versionNumber = 1;
        store.nodeIndex[101] = 0;
        store.data.ways[0].nodes[0].id = 101;
        store.data.relations[0].members[1].id = 101;

        require(store.wayIndex.remove(-2), "reference way remap delete failed");
        store.data.ways[0].id = 102;
        store.data.ways[0].metadata.hasVersion = true;
        store.data.ways[0].metadata.versionNumber = 1;
        store.wayIndex[102] = 0;
        store.data.relations[0].members[0].id = 102;

        require(store.relationIndex.remove(-3), "reference relation remap delete failed");
        store.data.relations[0].id = 103;
        store.data.relations[0].metadata.hasVersion = true;
        store.data.relations[0].metadata.versionNumber = 1;
        store.relationIndex[103] = 0;
    });

    result.checksum = traverseReference(store.data);
    return result;
}

private RemapMetrics runCompactRemap() @safe
{
    auto store = new OsmStore();
    StoreStatus status;

    OwnedNode node;
    node.id = -1;
    node.location = typeof(node.location)(1, 2);
    OsmHandle nodeHandle;
    require(store.add(node, nodeHandle, status), "compact remap node create failed");

    OwnedWay way;
    way.id = -2;
    way.nodes ~= OwnedWayNode(-1, false, typeof(node.location).init);
    OsmHandle wayHandle;
    require(store.add(way, wayHandle, status), "compact remap way create failed");

    OwnedRelation relation;
    relation.id = -3;
    OwnedRelationMember wayMember;
    wayMember.type = ElementType.way;
    wayMember.id = -2;
    OwnedRelationMember nodeMember;
    nodeMember.type = ElementType.node;
    nodeMember.id = -1;
    relation.members = [wayMember, nodeMember];
    OsmHandle relationHandle;
    require(store.add(relation, relationHandle, status), "compact remap relation create failed");

    RemapMetrics result;
    result.elapsedNs = elapsedNs(() {
        require(store.remapId(nodeHandle, 101, 1, status),
            "compact node remap failed");
        require(store.remapId(wayHandle, 102, 1, status),
            "compact way remap failed");
        require(store.remapId(relationHandle, 103, 1, status),
            "compact relation remap failed");
    });

    OsmHandle found;
    require(store.find(ElementType.node, 101, found), "remapped node missing");
    assert(found == nodeHandle);
    require(store.find(ElementType.way, 102, found), "remapped way missing");
    assert(found == wayHandle);
    require(store.find(ElementType.relation, 103, found), "remapped relation missing");
    assert(found == relationHandle);

    result.checksum = traverseCompact(store);
    return result;
}


private void collectCompactIds(
    OsmStore store,
    out OsmId[] nodeIds,
    out OsmId[] wayIds,
    out OsmId[] relationIds) @safe
{
    auto nodes = store.nodes;
    while (!nodes.empty)
    {
        nodeIds ~= nodes.front.id;
        nodes.popFront();
    }

    auto ways = store.ways;
    while (!ways.empty)
    {
        wayIds ~= ways.front.id;
        ways.popFront();
    }

    auto relations = store.relations;
    while (!relations.empty)
    {
        relationIds ~= relations.front.id;
        relations.popFront();
    }
}

private ParentKey[] makeRelationParentQueries(
    scope const(OsmId)[] nodeIds,
    scope const(OsmId)[] wayIds,
    scope const(OsmId)[] relationIds,
    size_t count) @safe
{
    ParentKey[] population;
    population.length = nodeIds.length + wayIds.length + relationIds.length;

    size_t at;
    foreach (id; nodeIds)
        population[at++] = ParentKey(ElementType.node, id);
    foreach (id; wayIds)
        population[at++] = ParentKey(ElementType.way, id);
    foreach (id; relationIds)
        population[at++] = ParentKey(ElementType.relation, id);

    ParentKey[] result;
    result.length = count;
    foreach (i; 0 .. count)
    {
        if (i % 10 == 9 || population.length == 0)
            result[i] = ParentKey(
                ElementType.node, long.min + cast(long)i + 11);
        else
            result[i] = population[(i * 65537UL) % population.length];
    }
    return result;
}

int main(string[] args)
{
    string variant;
    string filename;

    foreach (arg; args[1 .. $])
    {
        if (arg.startsWith("--variant="))
            variant = arg["--variant=".length .. $];
        else if (filename.length == 0)
            filename = arg;
        else
        {
            stderr.writefln("unexpected argument: %s", arg);
            return 2;
        }
    }

    if ((variant != "reference" &&
         variant != "compact" &&
         variant != "compact-owned") ||
        filename.length == 0)
    {
        stderr.writefln(
            "usage: %s --variant=reference|compact|compact-owned FILE.osm.pbf",
            args[0]);
        return 2;
    }

    const processStartRss = currentRssKiB();
    auto storage = cast(ubyte[])read(filename);
    const inputBytes = storage.length;
    const(ubyte)[] input = cast(const(ubyte)[])storage;

    if (variant == "compact-owned")
    {
        PbfDocument document;
        const decodeNs = measureSourceDecode(input, document);
        const expected = traverseReference(document.data);

        OsmStore materializedStore;
        StoreStatus status;
        const compactBuildNs = elapsedNs(() {
            require(OsmStore.build(document.data, materializedStore, status),
                "materialized compact build failed");
        });
        const actual = traverseCompact(materializedStore);

        if (actual != expected)
        {
            stderr.writefln(
                "materialized compact semantic mismatch expected=%s actual=%s",
                expected,
                actual);
            return 1;
        }

        writefln("variant=compact-owned");
        writefln("input_bytes=%s", inputBytes);
        writefln("source_decode_ns=%s", decodeNs);
        writefln("layout_build_ns=%s", compactBuildNs);
        writefln("semantic_checksum=%s", actual);
        writefln("integrity=pass");
        return 0;
    }

    long sourceDecodeNs;
    long layoutBuildNs;
    long parentBuildNs;
    size_t ownedBytes;
    ulong expectedChecksum;

    ParentIndexes parents;
    ReferenceStore reference;
    OsmStore compact;

    if (variant == "reference")
    {
        PbfDocument document;
        sourceDecodeNs = measureSourceDecode(input, document);
        expectedChecksum = traverseReference(document.data);

        parentBuildNs =
            elapsedNs(() { parents.build(document.data); });

        OwnedDataset moved = document.data;
        document.data = OwnedDataset.init;
        layoutBuildNs =
            elapsedNs(() { reference = new ReferenceStore(moved); });
        ownedBytes =
            reference.estimatedOwnedBytes + parents.logicalBytes;

        releaseDocumentEnvelope(document);
    }
    else
    {
        StoreStatus storeStatus;
        PbfReadSummary summary;
        sourceDecodeNs = 0;
        layoutBuildNs = measureDirectStoreBuild(
            input,
            compact,
            summary,
            storeStatus);

        const counts = compact.counts;
        require(summary.nodes == counts.liveNodes,
            "direct node count mismatch");
        require(summary.ways == counts.liveWays,
            "direct way count mismatch");
        require(summary.relations == counts.liveRelations,
            "direct relation count mismatch");

        expectedChecksum = traverseCompact(compact);
        parentBuildNs = 0;
        ownedBytes = compact.memoryUsage.totalOwnedBytes;
    }

    // The file bytes and reader scratch are not retained by either store.
    input = null;
    freeGcArray(storage);
    minimizeGc();

    const finalRss = currentRssKiB();
    const buildPeakRss = peakRssKiB();
    const finalIncremental =
        finalRss > processStartRss ? finalRss - processStartRss : 0;
    const peakIncremental =
        buildPeakRss > processStartRss ?
            buildPeakRss - processStartRss : 0;

    // Query arrays and edit plans are allocated after the retained-store RSS
    // sample so benchmark infrastructure is not charged to either layout.
    OsmId[] nodeIds;
    OsmId[] wayIds;
    OsmId[] relationIds;
    EditSelection editSelection;

    if (variant == "reference")
    {
        nodeIds = idsOf(reference.data.nodes);
        wayIds = idsOf(reference.data.ways);
        relationIds = idsOf(reference.data.relations);
        editSelection = makeEditSelection(reference.data);
    }
    else
    {
        collectCompactIds(compact, nodeIds, wayIds, relationIds);
        editSelection = makeEditSelection(compact);
    }

    auto nodeQueries = makeQueries(nodeIds, 1_000_000);
    auto wayQueries = makeQueries(wayIds, 250_000);
    auto relationQueries = makeQueries(relationIds, 50_000);
    auto parentNodeQueries = makeQueries(nodeIds, 250_000);
    auto parentRelationQueries = makeRelationParentQueries(
        nodeIds, wayIds, relationIds, 100_000);

    Timing nodeLookup;
    Timing wayLookup;
    Timing relationLookup;
    Timing traversal;

    if (variant == "reference")
    {
        nodeLookup = measureLookupReference(
            reference, ElementType.node, nodeQueries);
        wayLookup = measureLookupReference(
            reference, ElementType.way, wayQueries);
        relationLookup = measureLookupReference(
            reference, ElementType.relation, relationQueries);
        traversal = measureTraversalReference(reference.data);
    }
    else
    {
        nodeLookup = measureLookupCompact(
            compact, ElementType.node, nodeQueries);
        wayLookup = measureLookupCompact(
            compact, ElementType.way, wayQueries);
        relationLookup = measureLookupCompact(
            compact, ElementType.relation, relationQueries);
        traversal = measureTraversalCompact(compact);
    }

    Timing nodeParents;
    Timing relationParents;
    if (variant == "reference")
    {
        nodeParents =
            measureNodeParentsReference(parents, parentNodeQueries);
        relationParents =
            measureRelationParentsReference(parents, parentRelationQueries);
    }
    else
    {
        nodeParents =
            measureNodeParentsCompact(compact, parentNodeQueries);
        relationParents =
            measureRelationParentsCompact(compact, parentRelationQueries);

        // Parent semantics must match the straightforward reference answer set.
        ParentIndexes expectedParents;
        expectedParents.build(compact);
        const expectedNodeParents =
            measureNodeParentsReference(expectedParents, parentNodeQueries);
        const expectedRelationParents =
            measureRelationParentsReference(
                expectedParents, parentRelationQueries);
        require(nodeParents.checksum == expectedNodeParents.checksum,
            "compact Node->Way parent index mismatch");
        require(relationParents.checksum == expectedRelationParents.checksum,
            "compact element->Relation parent index mismatch");
    }

    if (traversal.checksum != expectedChecksum)
    {
        stderr.writefln(
            "semantic traversal mismatch expected=%s actual=%s",
            expectedChecksum,
            traversal.checksum);
        return 1;
    }

    EditMetrics edits;
    RemapMetrics remap;

    if (variant == "reference")
    {
        edits = runReferenceEdits(
            reference, editSelection, expectedChecksum, parents.logicalBytes);
        remap = runReferenceRemap();
    }
    else
    {
        edits = runCompactEdits(
            compact, editSelection, expectedChecksum, 0);
        remap = runCompactRemap();
    }

    writefln("variant=%s", variant);
    writefln("input_bytes=%s", inputBytes);
    writefln("source_decode_ns=%s", sourceDecodeNs);
    writefln("layout_build_ns=%s", layoutBuildNs);
    writefln("parent_build_ns=%s", parentBuildNs);
    writefln("build_ns=%s", sourceDecodeNs + layoutBuildNs + parentBuildNs);
    writefln("process_start_rss_kib=%s", processStartRss);
    writefln("final_rss_kib=%s", finalRss);
    writefln("peak_rss_kib=%s", buildPeakRss);
    writefln("final_incremental_rss_kib=%s", finalIncremental);
    writefln("peak_incremental_rss_kib=%s", peakIncremental);
    writefln("owned_bytes=%s", ownedBytes);
    writefln(
        "parent_index_bytes=%s",
        variant == "reference" ?
            parents.logicalBytes :
            compact.memoryUsage.parentIndexes);
    writefln("nodes=%s", nodeIds.length);
    writefln("ways=%s", wayIds.length);
    writefln("relations=%s", relationIds.length);

    printTiming("node_lookup", nodeLookup);
    printTiming("way_lookup", wayLookup);
    printTiming("relation_lookup", relationLookup);
    printTiming("node_parent_lookup", nodeParents);
    printTiming("relation_parent_lookup", relationParents);
    printTiming("traversal", traversal);

    writefln("edit_ns=%s", edits.editNs);
    writefln("edit_parent_rebuild_ns=%s", edits.parentUpdateNs);
    writefln("edit_checksum=%s", edits.editChecksum);
    writefln("post_edit_owned_bytes=%s", edits.postEditOwnedBytes);
    writefln("revert_ns=%s", edits.revertNs);
    writefln("revert_checksum=%s", edits.revertChecksum);
    writefln("post_revert_owned_bytes=%s", edits.postRevertOwnedBytes);
    writefln("remap_ns=%s", remap.elapsedNs);
    writefln("remap_checksum=%s", remap.checksum);

    writefln("semantic_checksum=%s", traversal.checksum);
    writefln("integrity=pass");
    return 0;
}
