module app;

import osm;
import std.file : read;
import std.stdio : stderr, writeln;

int main(string[] args)
{
    if (args.length != 2)
    {
        stderr.writeln("usage: pbf-store <input.osm.pbf>");
        return 2;
    }

    auto storage = read(args[1]);
    const(ubyte)[] input = cast(const(ubyte)[])storage;

    OsmStore store;
    PbfReadSummary summary;
    PbfStoreReadStatus status;
    if (!readPbfStore(input, store, summary, status))
    {
        if (!status.pbf.ok)
            stderr.writeln("PBF failure: ", status.pbf.error);
        else
            stderr.writeln("store failure: ", status.store.error);
        return 1;
    }

    const counts = store.counts;
    writeln("store nodes=", counts.liveNodes,
            " ways=", counts.liveWays,
            " relations=", counts.liveRelations,
            " owned-bytes=", store.memoryUsage.totalOwnedBytes);

    auto parents = store.parentWays(1);
    if (!parents.empty)
        writeln("first Way referencing node 1: ", parents.front.id);

    return 0;
}
