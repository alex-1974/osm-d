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

import osm.store.compact.store :
    KnownRelationMemberRewrite,
    KnownWayRefRewrite;

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
    ParentKey[] keys;
    ParentSpan[] spans;
    OsmId[] parents;
    uint[] buckets;

    void build(ParentEdge[] edges) @safe
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
        })(edges);

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
            spans ~= ParentSpan(
                cast(uint)parents.length,
                cast(uint)(end - begin));

            foreach (i; begin .. end)
                parents ~= edges[i].parent;

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
        ParentEdge[] nodeWayEdges;
        ParentEdge[] relationEdges;

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

private Timing measureNodeParents(
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
                mix(hash, values.length);
                foreach (parent; values)
                    mix(hash, cast(ulong)parent);
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

private Timing measureRelationParents(
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
                mix(hash, values.length);
                foreach (parent; values)
                    mix(hash, cast(ulong)parent);
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

    if ((variant != "reference" && variant != "compact") ||
        filename.length == 0)
    {
        stderr.writefln(
            "usage: %s --variant=reference|compact FILE.osm.pbf",
            args[0]);
        return 2;
    }

    const processStartRss = currentRssKiB();
    auto storage = cast(ubyte[])read(filename);
    const inputBytes = storage.length;
    const(ubyte)[] input = cast(const(ubyte)[])storage;

    PbfDocument document;
    const sourceDecodeNs = measureSourceDecode(input, document);

    const expectedChecksum = traverseReference(document.data);

    auto nodeIds = idsOf(document.data.nodes);
    auto wayIds = idsOf(document.data.ways);
    auto relationIds = idsOf(document.data.relations);

    auto nodeQueries = makeQueries(nodeIds, 1_000_000);
    auto wayQueries = makeQueries(wayIds, 250_000);
    auto relationQueries = makeQueries(relationIds, 50_000);
    auto parentNodeQueries = makeQueries(nodeIds, 250_000);
    auto parentRelationQueries =
        makeRelationParentQueries(document.data, 100_000);

    ParentIndexes parents;
    long parentBuildNs = elapsedNs(() { parents.build(document.data); });

    long layoutBuildNs;
    size_t ownedBytes;
    Timing nodeLookup;
    Timing wayLookup;
    Timing relationLookup;
    Timing traversal;

    ReferenceStore reference;
    OsmStore compact;

    if (variant == "reference")
    {
        OwnedDataset moved = document.data;
        document.data = OwnedDataset.init;

        layoutBuildNs = elapsedNs(() { reference = new ReferenceStore(moved); });
        ownedBytes = reference.estimatedOwnedBytes + parents.logicalBytes;

        document = PbfDocument.init;
        storage = null;
        minimizeGc();

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
        StoreStatus status;
        layoutBuildNs = elapsedNs(() {
            if (!OsmStore.build(document.data, compact, status))
            {
                stderr.writefln(
                    "compact store build failed: %s type=%s id=%s",
                    status.error,
                    status.type,
                    status.id);
                assert(0, "compact store build failed");
            }
        });

        ownedBytes = compact.memoryUsage.totalOwnedBytes +
                     parents.logicalBytes;

        document = PbfDocument.init;
        storage = null;
        minimizeGc();

        nodeLookup = measureLookupCompact(
            compact, ElementType.node, nodeQueries);
        wayLookup = measureLookupCompact(
            compact, ElementType.way, wayQueries);
        relationLookup = measureLookupCompact(
            compact, ElementType.relation, relationQueries);
        traversal = measureTraversalCompact(compact);
    }

    const nodeParents =
        measureNodeParents(parents, parentNodeQueries);
    const relationParents =
        measureRelationParents(parents, parentRelationQueries);

    if (traversal.checksum != expectedChecksum)
    {
        stderr.writefln(
            "semantic traversal mismatch expected=%s actual=%s",
            expectedChecksum,
            traversal.checksum);
        return 1;
    }

    minimizeGc();
    const finalRss = currentRssKiB();
    const peakRss = peakRssKiB();

    const finalIncremental =
        finalRss > processStartRss ? finalRss - processStartRss : 0;
    const peakIncremental =
        peakRss > processStartRss ? peakRss - processStartRss : 0;

    writefln("variant=%s", variant);
    writefln("input_bytes=%s", inputBytes);
    writefln("source_decode_ns=%s", sourceDecodeNs);
    writefln("layout_build_ns=%s", layoutBuildNs);
    writefln("parent_build_ns=%s", parentBuildNs);
    writefln("build_ns=%s", sourceDecodeNs + layoutBuildNs + parentBuildNs);
    writefln("process_start_rss_kib=%s", processStartRss);
    writefln("final_rss_kib=%s", finalRss);
    writefln("peak_rss_kib=%s", peakRss);
    writefln("final_incremental_rss_kib=%s", finalIncremental);
    writefln("peak_incremental_rss_kib=%s", peakIncremental);
    writefln("owned_bytes=%s", ownedBytes);
    writefln("parent_index_bytes=%s", parents.logicalBytes);
    writefln("nodes=%s", nodeIds.length);
    writefln("ways=%s", wayIds.length);
    writefln("relations=%s", relationIds.length);
    printTiming("node_lookup", nodeLookup);
    printTiming("way_lookup", wayLookup);
    printTiming("relation_lookup", relationLookup);
    printTiming("node_parent_lookup", nodeParents);
    printTiming("relation_parent_lookup", relationParents);
    printTiming("traversal", traversal);
    writefln("semantic_checksum=%s", traversal.checksum);
    writefln("integrity=pass");

    return 0;
}
