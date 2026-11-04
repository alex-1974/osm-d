module app;

import osm;
import std.file : read, write;
import std.stdio : stderr;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: pbf-roundtrip <input.osm.pbf> <output.osm.pbf>");
        return 2;
    }

    auto storage = read(args[1]);
    const(ubyte)[] input = cast(const(ubyte)[])storage;

    PbfDocument document;
    PbfReadStatus readStatus;
    if (!readPbfDocument(input, document, readStatus))
    {
        stderr.writeln("PBF read failed: ", readStatus.error);
        return 1;
    }

    PbfWriter writer;
    PbfWriteStatus writeStatus;
    ubyte[] output;
    if (!writer.write(document, output, writeStatus))
    {
        stderr.writeln("semantic rewrite refused: ", writeStatus.error);
        return 1;
    }

    write(args[2], output);
    return 0;
}
