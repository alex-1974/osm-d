module app;

import osm;
import osm.pbf;
import osm.osmchange;
import osm.validate;
import osm.xml;
import osm.compare : sameChangeSemantics, sameOsmSemantics;
import osm.model.owned : OwnedWayNode;
import osm.view.way_node : WayNodeView;
import osm.api :
    EditingApiClient,
    EditingApiServer,
    EditingApiStatus;
import osm.area :
    AreaAssemblyResult;
import osm.changeset :
    ChangesetTagRequest,
    OwnedChangeset;
import osm.complete :
    CompleteObjectState;
import osm.history :
    HistoricalNodeVersion,
    NodeHistory;
import osm.replication :
    ReplicationApplyResult,
    ReplicationFeed,
    ReplicationGranularity,
    ReplicationIngestOptions,
    ReplicationIngestStatus,
    ReplicationPathStatus,
    ReplicationResourcePaths,
    ReplicationState,
    ReplicationTimestamp,
    replicationResourcePaths;
import osm.sync :
    AuthoritativeBatch,
    ReconcileResult,
    ReconcileStatus;
import osm.topology :
    TopologyTraversalWorkspace;
import transport.source : MemorySink, MemorySource;

@safe void compileRootAndNamedArguments()
{
    static assert(is(OsmId == long));
    static assert(OsmHandle.init.valid == false);
    static assert(LocationView.init.latitudeNanodegrees == 0);
    static assert(LocationView.init.longitudeNanodegrees == 0);
    static assert(PbfReadStatus.init.ok);
    static assert(PbfWriteStatus.init.ok);
    static assert(PbfStoreReadStatus.init.ok);
    static assert(StoreStatus.init.ok);
    static assert(UploadResult.init.empty);
    static assert(!UploadResultEntry.init.shapeValid);
    static assert(is(WayNodeView == NodeRefView));
    static assert(is(OwnedWayNode == OwnedNodeRef));
    static assert(is(typeof(&sameOsmSemantics)));
    static assert(is(typeof(&sameChangeSemantics)));

    const(ubyte)[] input;

    PbfDocument document;
    PbfReadStatus pbfStatus;
    const readOk = readPbfDocument(
        input: input,
        document: document,
        status: pbfStatus);
    assert(!readOk);

    OsmStore store;
    PbfReadSummary summary;
    PbfStoreReadStatus storeReadStatus;
    const storeOk = readPbfStore(
        input: input,
        store: store,
        summary: summary,
        status: storeReadStatus);
    assert(!storeOk);
    assert(store is null);

    auto editable = new OsmStore();
    OwnedNode node;
    node.id = -1;
    node.location = LocationView(1, 2);

    OsmHandle handle;
    StoreStatus status;
    assert(editable.add(
        value: node,
        handle: handle,
        status: status));

    StoreNodeView direct;
    assert(editable.node(
        id: -1,
        value: direct,
        status: status));
    assert(direct.handle == handle);

    OsmHandle found;
    assert(editable.find(
        type: ElementType.node,
        id: -1,
        handle: found));
    assert(found == handle);

    OwnedChangeSequence uploadChanges;
    assert(editable.collectChanges(
        changes: uploadChanges,
        status: status));
    assert(uploadChanges.entries.length == 1);
    assert(uploadChanges.setChangeset(changesetId: 55));

    UploadResult uploadResult;
    uploadResult.entries ~= UploadResultEntry.created(
        type: ElementType.node,
        oldId: -1,
        newId: 1001,
        newVersion: 1);
    UploadResultEffect effect;
    assert(uploadResult.entries[0].effectFor(
        uploaded: uploadChanges.entries[0],
        effect: effect));
    assert(effect == UploadResultEffect.created);
    assert(editable.applyUploadResult(
        uploaded: uploadChanges,
        result: uploadResult,
        status: status));

    auto parentWays = editable.parentWays(nodeId: 1001);
    auto parentRelations = editable.parentRelations(
        type: ElementType.node,
        id: 1001);
    assert(parentWays.empty);
    assert(parentRelations.empty);

    PbfWriter writer;
    PbfWriteOptions writeOptions;
    PbfWriteStatus writeStatus;
    ubyte[] output;
    document = PbfDocument.create();
    assert(writer.write(
        document: document,
        output: output,
        status: writeStatus,
        options: writeOptions));
}

@safe void compileXmlFacade()
{
    enum xml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" ~
        "<osm version=\"0.6\" generator=\"release-consumer\"></osm>";

    auto source = new MemorySource(cast(const(ubyte)[])xml);
    OsmXmlDocument document;
    OsmXmlReadStatus readStatus;
    OsmXmlReadOptions readOptions;

    assert(readOsmXmlDocument(
        source: source,
        document: document,
        status: readStatus,
        options: readOptions));

    auto sink = new MemorySink();
    OsmXmlWriter writer;
    OsmXmlWriteStatus writeStatus;
    OsmXmlWriteOptions writeOptions;
    assert(writer.write(
        document: document,
        sink: sink,
        status: writeStatus,
        options: writeOptions));
}

@safe void compileOsmChangeAndValidationFacade()
{
    OwnedChangeSequence changes;

    CapabilityProfile capabilities;
    UploadValidationIssue issue;
    assert(validateUploadChanges(
        changes: changes,
        capabilities: capabilities,
        issue: issue));

    OsmChangeDocument document;
    document.changes = changes;

    auto sink = new MemorySink();
    OsmChangeWriter writer;
    OsmChangeWriteStatus writeStatus;
    OsmChangeWriteOptions writeOptions;
    assert(writer.write(
        document: document,
        sink: sink,
        status: writeStatus,
        options: writeOptions));

    auto source = new MemorySource(sink.data);
    OsmChangeDocument reread;
    OsmChangeReadStatus readStatus;
    OsmChangeReadOptions readOptions;
    assert(readOsmChangeDocument(
        source: source,
        document: reread,
        status: readStatus,
        options: readOptions));
}

@safe void compileV04Facades()
{
    static assert(is(EditingApiClient));
    static assert(is(EditingApiServer));
    static assert(is(EditingApiStatus));
    static assert(is(ChangesetTagRequest));
    static assert(is(OwnedChangeset));
    static assert(is(HistoricalNodeVersion));
    static assert(is(NodeHistory));
    static assert(is(AuthoritativeBatch));
    static assert(is(ReconcileResult));
    static assert(is(ReconcileStatus));
    static assert(is(TopologyTraversalWorkspace));
    static assert(is(CompleteObjectState));
    static assert(is(AreaAssemblyResult));
    static assert(is(ReplicationApplyResult));
    static assert(is(ReplicationIngestOptions));
    static assert(is(ReplicationIngestStatus));

    ReplicationFeed feed;
    assert(ReplicationFeed.create(
        id: "release-consumer",
        granularity: ReplicationGranularity.minute,
        result: feed));

    ReplicationState state;
    state.sequenceNumber = 123_456;
    state.timestamp = ReplicationTimestamp.fromUnixSeconds(
        seconds: 1_762_620_000);

    ReplicationResourcePaths paths;
    ReplicationPathStatus pathStatus;
    assert(replicationResourcePaths(
        sequenceNumber: state.sequenceNumber,
        paths: paths,
        status: pathStatus));
    assert(pathStatus.ok);
    assert(paths.change.length != 0);
    assert(paths.state.length != 0);
}

@safe void main()
{
    compileRootAndNamedArguments();
    compileXmlFacade();
    compileOsmChangeAndValidationFacade();
    compileV04Facades();
}
