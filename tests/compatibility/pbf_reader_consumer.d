module pbf_reader_consumer;

import osm;

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
    auto tags = value.tags;

    while (!tags.empty)
    {
        auto tag = tags.front;
        const key = tag.key;
        const tagValue = tag.value;

        assert(key == tag.key);
        assert(tagValue == tag.value);

        tags.popFront();
    }
}

struct Consumer
{
    size_t nodes;
    size_t ways;
    size_t relations;

    void node(T)(scope ref T value) @safe nothrow @nogc
    {
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

    void way(T)(scope ref T value) @safe nothrow @nogc
    {
        ++ways;
        assert(value.type == ElementType.way);

        inspectMetadata(value);
        inspectTags(value);

        auto refs = value.refs;
        while (!refs.empty)
        {
            OsmId nodeId = refs.front;
            assert(nodeId == refs.front);
            refs.popFront();
        }

        auto locations = value.locations;
        while (!locations.empty)
        {
            LocationView location = locations.front;
            const latitude = location.latitude;
            const longitude = location.longitude;

            assert(latitude == location.latitude);
            assert(longitude == location.longitude);

            locations.popFront();
        }
    }

    void relation(T)(scope ref T value) @safe nothrow @nogc
    {
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
    PbfReader reader;
    PbfReaderWorkspace workspace;
    Consumer consumer;
    PbfReadSummary summary;
    PbfReadStatus status;
    const(ubyte)[] input;

    const ok = reader.read(input, workspace, consumer, summary, status);
    assert(!ok);
    assert(status.error == PbfReadError.missingHeader);
}
