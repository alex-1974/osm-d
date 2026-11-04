module io_baseline;

import osm;
import osm.model.compare : sameOsmSemantics;
import osm.xml;
import std.algorithm.sorting : sort;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : writefln, writeln;
import transport.source : MemorySink, MemorySource;

private enum rounds = 5;

private long elapsedNsecs(scope void delegate() operation)
{
    StopWatch sw = StopWatch(AutoStart.yes);
    operation();
    sw.stop();
    return sw.peek.total!"nsecs";
}

private double medianMillis(long[rounds] samples)
{
    sort(samples[]);
    return cast(double)samples[rounds / 2] / 1_000_000.0;
}

private void require(bool condition, string message)
{
    if (!condition)
        throw new Exception(message);
}

void main(string[] args)
{
    require(args.length == 2, "usage: release-io <input.osm.pbf>");

    auto storage = read(args[1]);
    const(ubyte)[] input = cast(const(ubyte)[])storage;

    PbfDocument source;
    PbfReadStatus readStatus;
    require(readPbfDocument(input, source, readStatus),
        "failed to materialize benchmark PBF");

    // Benchmark semantic writing independently of unknown raw-source
    // preservation state while retaining the source's known header semantics.
    PbfDocument semantic = source.deepCopy();
    semantic.preservation = PbfPreservation.init;

    long[rounds] pbfWriteSamples;
    ubyte[] pbfOutput;
    foreach (i; 0 .. rounds)
    {
        pbfWriteSamples[i] = elapsedNsecs({
            PbfWriter writer;
            PbfWriteStatus status;
            ubyte[] output;
            require(writer.write(semantic, output, status),
                "semantic PBF write failed");
            pbfOutput = output;
        });
    }

    PbfDocument pbfReread;
    require(readPbfDocument(pbfOutput, pbfReread, readStatus),
        "generated PBF could not be read");
    require(sameOsmSemantics(source.data, pbfReread.data),
        "generated PBF changed OSM semantics");

    long[rounds] xmlWriteSamples;
    immutable(ubyte)[] xmlOutput;
    foreach (i; 0 .. rounds)
    {
        xmlWriteSamples[i] = elapsedNsecs({
            auto sink = new MemorySink();
            OsmXmlWriter writer;
            OsmXmlWriteStatus status;
            require(writer.writeDataset(source.data, sink, status),
                "OSM XML write failed");
            xmlOutput = sink.data.idup;
        });
    }

    long[rounds] xmlReadSamples;
    OsmXmlDocument xmlReread;
    foreach (i; 0 .. rounds)
    {
        xmlReadSamples[i] = elapsedNsecs({
            auto sourceBytes = new MemorySource(xmlOutput);
            OsmXmlDocument document;
            OsmXmlReadStatus status;
            require(readOsmXmlDocument(sourceBytes, document, status),
                "generated OSM XML could not be read");
            xmlReread = document;
        });
    }

    require(sameOsmSemantics(source.data, xmlReread.data),
        "generated OSM XML changed OSM semantics");

    writeln("dataset_bytes=", input.length);
    writeln("nodes=", source.data.nodes.length);
    writeln("ways=", source.data.ways.length);
    writeln("relations=", source.data.relations.length);
    writeln("pbf_output_bytes=", pbfOutput.length);
    writeln("xml_output_bytes=", xmlOutput.length);
    writefln("pbf_write_p50_ms=%.3f", medianMillis(pbfWriteSamples));
    writefln("xml_write_p50_ms=%.3f", medianMillis(xmlWriteSamples));
    writefln("xml_read_p50_ms=%.3f", medianMillis(xmlReadSamples));
    writeln("semantic_parity=pass");
}
