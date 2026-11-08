module app;

import osm.store :
    OsmHandle,
    OsmStore,
    StoreStatus;
import osm.sync :
    AuthoritativeBatch,
    ConflictDisposition,
    NodeState,
    ReconcileResult,
    ReconcileStatus,
    classifyConflict,
    reconcileAuthoritative;
import osm.model.owned : OwnedNode;
import osm.view.location : LocationView;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writefln;

enum size_t classificationCount = 200_000;
enum size_t refreshCount = 10_000;

@safe void main()
{
    measureClassification();
    measureRefresh();
}

private void measureClassification() @safe
{
    OwnedNode base;
    base.id = 1;
    base.metadata.hasVersion = true;
    base.metadata.versionNumber = 1;
    base.location = LocationView(10, 20);

    auto local = base.deepCopy();
    local.location = LocationView(11, 20);

    auto remote = base.deepCopy();
    remote.metadata.versionNumber = 2;
    remote.location = LocationView(10, 21);

    auto baseState = NodeState.present(base);
    auto localState = NodeState.present(local);
    auto remoteState = NodeState.present(remote);

    StopWatch watch;
    watch.start();

    size_t conflicts;
    foreach (ignored; 0 .. classificationCount)
    {
        auto report = classifyConflict(
            baseState,
            localState,
            remoteState);
        if (report.disposition ==
            ConflictDisposition.conflict)
            ++conflicts;
    }

    watch.stop();
    if (conflicts != classificationCount)
        throw new Exception("unexpected conflict-classification result");

    writefln(
        "M18_CONFLICT_CLASSIFICATION count=%s conflicts=%s elapsed_us=%s",
        classificationCount,
        conflicts,
        watch.peek.total!"usecs");
}

private void measureRefresh() @safe
{
    auto store = new OsmStore();
    StoreStatus storeStatus;
    OsmHandle handle;

    AuthoritativeBatch batch;
    batch.nodes.length = refreshCount;

    foreach (i; 0 .. refreshCount)
    {
        OwnedNode node;
        node.id = cast(long)i + 1;
        node.metadata.hasVersion = true;
        node.metadata.versionNumber = 1;
        node.location = LocationView(
            48_000_000_000L + cast(long)i,
            16_000_000_000L + cast(long)i);
        if (!store.add(node, handle, storeStatus))
            throw new Exception("failed to build refresh workload");

        auto remote = node.deepCopy();
        remote.metadata.versionNumber = 2;
        remote.location = LocationView(
            node.location.latitudeNanodegrees + 1,
            node.location.longitudeNanodegrees);
        batch.nodes[i] = NodeState.present(remote);
    }

    StopWatch watch;
    watch.start();

    ReconcileResult result;
    ReconcileStatus status;
    if (!reconcileAuthoritative(
            store,
            batch,
            result,
            status))
        throw new Exception("authoritative refresh failed");

    watch.stop();

    if (result.refreshed != refreshCount ||
        result.conflicts != 0 ||
        result.deferred != 0)
        throw new Exception("unexpected authoritative-refresh result");

    const counts = store.counts;
    if (counts.liveNodes != refreshCount)
        throw new Exception("unexpected refreshed store size");

    writefln(
        "M18_AUTHORITATIVE_REFRESH count=%s refreshed=%s live_nodes=%s elapsed_us=%s",
        refreshCount,
        result.refreshed,
        counts.liveNodes,
        watch.peek.total!"usecs");
}
