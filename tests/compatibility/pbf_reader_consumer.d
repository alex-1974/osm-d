module pbf_reader_consumer;

import osm;

struct Consumer
{
    size_t nodes;

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
