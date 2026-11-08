module pbf_reader_consumer;

import osm;
import osm.pbf;
import osm.model.owned : OwnedWayNode;
import osm.view.way_node : WayNodeView;
import transport : ByteSource, MemorySource, ReadError;

// v0.1 compatibility aliases remain available from their old direct modules.
static assert(is(WayNodeView == NodeRefView));
static assert(is(OwnedWayNode == OwnedNodeRef));

private bool positiveNodeId(scope ref NodeView value)
    @safe pure nothrow @nogc
{
    return value.id > 0;
}

private bool highwayWay(scope ref WayView value)
    @safe nothrow @nogc
{
    return value.tags.hasTag("highway");
}

private bool positiveRelationId(scope ref RelationView value)
    @safe pure nothrow @nogc
{
    return value.id > 0;
}

private void inspectMetadata(T)(scope ref T value) @safe nothrow @nogc
{
    MetadataView metadata = value.metadata;

    if (metadata.hasVersion)
    {
        const versionNumber = metadata.versionNumber;
        assert(versionNumber == metadata.versionNumber);
    }

    if (metadata.hasTimestamp)
    {
        const timestampMilliseconds = metadata.timestampMilliseconds;
        assert(timestampMilliseconds == metadata.timestampMilliseconds);
    }

    if (metadata.hasChangeset)
    {
        const changesetId = metadata.changesetId;
        assert(changesetId == metadata.changesetId);
    }

    if (metadata.hasUserId)
    {
        const userId = metadata.userId;
        assert(userId == metadata.userId);
    }

    if (metadata.hasUsername)
    {
        const username = metadata.username;
        assert(username == metadata.username);
    }

    if (metadata.hasVisibility)
    {
        const visible = metadata.visible;
        assert(visible == metadata.visible);
    }
}

private void inspectTags(T)(scope ref T value) @safe nothrow @nogc
{
    static assert(!__traits(hasMember, TagView, "keySid"));
    static assert(!__traits(hasMember, TagView, "valueSid"));

    auto tags = value.tags;

    // Lookup helpers consume only a copy of the borrowed range cursor.
    const hasName = tags.hasTag("name");
    assert(hasName || !hasName);

    if (!tags.empty)
    {
        const expected = tags.front;
        TagLookupResult found = tags.findTag(expected.key);
        assert(found.found);
        assert(found.tag.key == expected.key);
        assert(found.tag.value == expected.value);
        assert(tags.tagEquals(expected.key, expected.value));
    }

    while (!tags.empty)
    {
        TagView tag = tags.front;
        const key = tag.key;
        const tagValue = tag.value;

        assert(key == tag.key);
        assert(tagValue == tag.value);

        tags.popFront();
    }
}

static assert(!__traits(compiles, (scope ref NodeView value)
{
    // NodeView callback borrow is deliberately non-copyable; copy semantic
    // subviews/ranges instead of retaining the callback wrapper itself.
    NodeView copy = value;
}));

struct Consumer
{
    size_t nodes;
    size_t ways;
    size_t relations;

    void node(scope ref NodeView value) @safe nothrow @nogc
    {
        static assert(!__traits(compiles, value.latNano));
        static assert(!__traits(compiles, value.lonNano));
        static assert(!__traits(compiles, value.info));
        static assert(!__traits(compiles, value.raw));
        static assert(!__traits(compiles, value.rawOffset));

        ++nodes;

        OsmId id = value.id;
        ElementType type = value.type;
        assert(type == ElementType.node);
        assert(id == value.id);

        LocationView location = value.location;
        const exactLatitude = location.latitudeNanodegrees;
        const exactLongitude = location.longitudeNanodegrees;
        const latitude = location.latitude;
        const longitude = location.longitude;

        assert(exactLatitude == location.latNano);
        assert(exactLongitude == location.lonNano);
        assert(latitude == location.latitude);
        assert(longitude == location.longitude);

        inspectMetadata(value);
        inspectTags(value);
    }

    void way(scope ref WayView value) @safe nothrow @nogc
    {
        static assert(!__traits(compiles, value.refs));
        static assert(!__traits(compiles, value.locations));
        static assert(!__traits(compiles, value.info));
        static assert(!__traits(compiles, value.raw));
        static assert(!__traits(compiles, value.rawOffset));

        ++ways;
        assert(value.type == ElementType.way);

        inspectMetadata(value);
        inspectTags(value);

        auto nodes = value.nodes;
        while (!nodes.empty)
        {
            NodeRefView node = nodes.front;
            OsmId nodeId = node.id;
            assert(nodeId == node.id);

            if (node.hasLocation)
            {
                LocationView location = node.location;
                const latitude = location.latitude;
                const longitude = location.longitude;

                assert(latitude == location.latitude);
                assert(longitude == location.longitude);
            }

            nodes.popFront();
        }
    }

    void relation(scope ref RelationView value) @safe nothrow @nogc
    {
        static assert(!__traits(compiles, value.info));
        static assert(!__traits(compiles, value.raw));
        static assert(!__traits(compiles, value.rawOffset));

        ++relations;
        assert(value.type == ElementType.relation);

        inspectMetadata(value);
        inspectTags(value);

        auto members = value.members;
        while (!members.empty)
        {
            RelationMemberView member = members.front;
            ElementType memberType = member.type;
            OsmId memberId = member.id;
            const role = member.role;

            assert(memberType == member.type);
            assert(memberId == member.id);
            assert(role == member.role);

            members.popFront();
        }
    }
}

void compileConsumer()
{
    Consumer consumer;
    const(ubyte)[] input;

    const result = readPbf(input, consumer);
    assert(!result.ok);
    assert(result.status.error == PbfReadError.missingHeader);

    // Advanced callers can still retain a workspace explicitly.
    PbfReader reader;
    PbfReaderWorkspace workspace;
    PbfReadSummary summary;
    PbfReadStatus status;
    const ok = reader.read(input, workspace, consumer, summary, status);
    assert(!ok);

    ByteSource source = new MemorySource(input);
    PbfSourceReadStatus sourceStatus;
    const sourceOk = reader.read(
        source,
        workspace,
        consumer,
        summary,
        sourceStatus);
    assert(!sourceOk);
    assert(sourceStatus.transportError == ReadError.none);
    assert(sourceStatus.pbf.error == PbfReadError.missingHeader);

    const sourceResult = readPbf(source, consumer);
    assert(!sourceResult.ok);
    assert(sourceResult.status.transportError == ReadError.none);
    assert(sourceResult.status.pbf.error == PbfReadError.missingHeader);

    auto nodes = pbfNodes(input);
    foreach (scope ref NodeView node; nodes)
    {
        OsmId id = node.id;
        assert(id == node.id);
        break;
    }

    PbfReadStatus nodeStatus = nodes.status;
    const nodeCompleted = nodes.completed;
    assert(!nodeStatus.ok);
    assert(!nodeCompleted);

    auto filteredNodes = pbfNodes(input).where!positiveNodeId;
    foreach (scope ref NodeView node; filteredNodes)
    {
        assert(node.id > 0);
    }
    assert(filteredNodes.status.ok || !filteredNodes.completed);
}


@safe void compileSafeNodeForeach(const(ubyte)[] input)
{
    PbfReader reader;
    auto nodes = reader.nodes(input);

    foreach (scope ref NodeView node; nodes)
    {
        OsmId id = node.id;
        assert(id == node.id);
        break;
    }

    PbfReadStatus status = nodes.status;
    const completed = nodes.completed;
    assert(status.ok || !completed);
}


@safe void compileSafeWayRelationForeach(const(ubyte)[] input)
{
    PbfReader reader;

    auto ways = reader.ways(input);
    foreach (scope ref WayView way; ways)
    {
        OsmId id = way.id;
        assert(id == way.id);
        break;
    }
    assert(ways.status.ok || !ways.completed);

    auto filteredWays = reader.ways(input).where!highwayWay;
    foreach (scope ref WayView way; filteredWays)
    {
        assert(way.tags.hasTag("highway"));
        break;
    }
    assert(filteredWays.status.ok || !filteredWays.completed);

    auto relations = reader.relations(input);
    foreach (scope ref RelationView relation; relations)
    {
        OsmId id = relation.id;
        assert(id == relation.id);
        break;
    }
    assert(relations.status.ok || !relations.completed);

    auto filteredRelations =
        reader.relations(input).where!positiveRelationId;
    foreach (scope ref RelationView relation; filteredRelations)
    {
        assert(relation.id > 0);
        break;
    }
    assert(filteredRelations.status.ok || !filteredRelations.completed);
}


@safe void compileSafeParallelSummary(const(ubyte)[] input)
{
    PbfParallelReader reader;
    PbfParallelReadOptions options;
    options.workerCount = 1;
    options.queueCapacity = 1;

    PbfReadSummary summary;
    PbfReadStatus status;
    const ok = reader.readSummary(input, options, summary, status);

    assert(ok || !status.ok);
}


@safe void compileOwnedDocumentSurface()
{
    OwnedDataset dataset;

    OwnedNode node;
    node.id = 1;
    node.location = LocationView(1, 2);
    node.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"key"),
        ownBytes(cast(const(ubyte)[])"value"));
    dataset.nodes ~= node;

    PbfDocument document = PbfDocument.create(dataset);
    assert(document.header.requiredFeatures.length == 1);
    assert(document.preservation.semanticRewriteSafe);

    PbfDocument copy = document.deepCopy();
    copy.data.nodes[0].tags.length = 0;
    assert(document.data.nodes[0].tags.length == 1);

    const(ubyte)[] rawBytes = [1, 2, 3];
    PbfRawFile raw = PbfRawFile.capture(rawBytes);
    assert(raw.bytes == rawBytes);

    PbfPreservation preservation;
    preservation.source = raw;
    preservation.reason = PbfPreservationReason.unknownField;
    assert(!preservation.semanticRewriteSafe);
}


@safe void compileLossAwareDocumentRead(const(ubyte)[] input)
{
    PbfDocument document;
    PbfReadStatus status;
    const ok = readPbfDocument(input, document, status);

    if (ok)
    {
        assert(status.ok);
        const rewriteSafe = document.preservation.semanticRewriteSafe;
        assert(rewriteSafe || document.preservation.hasSource);
    }
    else
    {
        assert(document.preservation.hasSource || input.length == 0);
    }
}


@safe void compilePbfWriterSurface()
{
    PbfDocument document = PbfDocument.create();
    PbfWriter writer;
    PbfWriteOptions options;
    PbfWriteStatus status;
    ubyte[] output;

    const ok = writer.write(document, output, status, options);
    assert(ok == status.ok);

    ubyte[] original;
    PbfWriteStatus originalStatus;
    const originalOk =
        writer.writeOriginalSource(document, original, originalStatus);
    assert(originalOk || originalStatus.error == PbfWriteError.noOriginalSource);
}


@safe void compileChangeModelSurface()
{
    OwnedNode node;
    node.id = -1;
    node.location = LocationView(48_208_174_300L, 16_373_818_900L);
    node.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"amenity"),
        ownBytes(cast(const(ubyte)[])"bench"));

    OwnedChangeEntry created =
        OwnedChangeEntry.fromNode(ChangeAction.create, node);
    assert(created.complete);
    assert(created.shapeValid);
    assert(created.objectState == ChangeObjectState.complete);

    OwnedMetadata deletionMetadata;
    deletionMetadata.hasVersion = true;
    deletionMetadata.versionNumber = 3;
    deletionMetadata.hasChangeset = true;
    deletionMetadata.changesetId = 7;

    OwnedChangeEntry deleted = OwnedChangeEntry.deletion(
        ElementType.node, 42, deletionMetadata, true);
    assert(deleted.action == ChangeAction.deleteObject);
    assert(!deleted.complete);
    assert(deleted.deleteIfUnused);
    assert(deleted.shapeValid);

    OwnedChangeSequence changes;
    changes.entries ~= created;
    changes.entries ~= deleted;

    auto copy = changes.deepCopy();
    assert(copy.entries.length == 2);
}
