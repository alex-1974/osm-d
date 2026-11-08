module app;

import osm.replication;
import osm.store : OsmStore;
import osm.osmchange : OsmChangeDocument;
import transport.source : ByteSource;

@safe void main()
{
    ReplicationFeed feed;
    ReplicationFeed.create(
        "consumer-feed",
        ReplicationGranularity.custom,
        feed);

    ReplicationState state;
    ReplicationStateReadStatus readStatus;
    ByteSource source;

    ReplicationResourcePaths paths;
    ReplicationPathStatus pathStatus;

    ReplicationCheckpoint checkpoint;
    ReplicationApplyResult result;
    ReplicationApplyStatus applyStatus;
    ReplicationIngestOptions ingestOptions;
    ReplicationIngestStatus ingestStatus;
    OsmChangeDocument document;

    if (false)
    {
        readReplicationState(source, state, readStatus);
        replicationResourcePaths(
            state.sequenceNumber,
            paths,
            pathStatus);
        classifyReplicationStep(checkpoint, feed, state);
        applyReplicationStep(
            new OsmStore(),
            checkpoint,
            feed,
            state,
            document,
            result,
            applyStatus);
        applyGzipReplicationStep(
            new OsmStore(),
            source,
            checkpoint,
            feed,
            state,
            result,
            ingestStatus,
            ingestOptions);
    }
}
