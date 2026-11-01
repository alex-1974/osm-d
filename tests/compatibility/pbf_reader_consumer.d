module pbf_reader_consumer;

import osm;

struct Consumer
{
    size_t nodes;

    void node(T)(scope ref T value) @safe nothrow @nogc
    {
        ++nodes;
        const id = value.id;
        assert(id == value.id);
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
