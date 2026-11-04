module app;

import osm;
import std.file : read;
import std.stdio : stderr, writeln;

struct Counter
{
    ulong nodes;
    ulong ways;
    ulong relations;

    void node(scope ref NodeView) @safe nothrow @nogc { ++nodes; }
    void way(scope ref WayView) @safe nothrow @nogc { ++ways; }
    void relation(scope ref RelationView) @safe nothrow @nogc { ++relations; }
}

int main(string[] args)
{
    if (args.length != 2)
    {
        stderr.writeln("usage: pbf-read <input.osm.pbf>");
        return 2;
    }

    auto storage = read(args[1]);
    const(ubyte)[] input = cast(const(ubyte)[])storage;

    Counter counter;
    const result = readPbf(input, counter);
    if (!result.ok)
    {
        stderr.writeln("PBF read failed: ", result.status.error);
        return 1;
    }

    writeln("nodes=", counter.nodes,
            " ways=", counter.ways,
            " relations=", counter.relations,
            " tags=", result.summary.tags);
    return 0;
}
