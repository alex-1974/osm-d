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
    }

    void way(T)(scope ref T value) @safe nothrow @nogc
    {
        ++ways;
        assert(value.type == ElementType.way);
        inspectMetadata(value);
    }

    void relation(T)(scope ref T value) @safe nothrow @nogc
    {
        ++relations;
        assert(value.type == ElementType.relation);
        inspectMetadata(value);
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
