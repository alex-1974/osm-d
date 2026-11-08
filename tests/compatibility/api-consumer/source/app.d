
module app;

import osm.api;
import transport.exchange :
    HttpExchange,
    HttpExchangeError,
    HttpExchangeErrorKind,
    HttpExchangeResult,
    HttpRequest;

private final class ConsumerExchange : HttpExchange
{
    HttpExchangeResult exchange(scope const ref HttpRequest request) @safe
    {
        return HttpExchangeResult.failure(
            HttpExchangeError(HttpExchangeErrorKind.transportFailure));
    }
}

@safe void main()
{
    auto client = new EditingApiClient(
        EditingApiServer("https://example.test/api/0.6"),
        new ConsumerExchange());

    EditingApiStatus status;
    EditingApiCapabilitiesDocument capabilities;
    EditingApiPermissions permissions;
    OwnedNode node;
    NodeHistory nodeHistory;
    OwnedWay way;
    WayHistory wayHistory;
    OwnedRelation relation;
    RelationHistory relationHistory;
    OwnedDataset dataset;
    ChangesetTagRequest changesetRequest;
    ChangesetId changesetId;
    OwnedChangeset changeset;
    OwnedChangeSequence changes;
    UploadResult uploadResult;

    if (false)
    {
        client.readCapabilities(capabilities, status);
        client.readPermissions(permissions, status);
        client.readNode(1, node, status);
        client.readNodeVersion(1, 1, node, status);
        client.readNodeHistory(1, nodeHistory, status);
        client.readWay(1, way, status);
        client.readWayVersion(1, 1, way, status);
        client.readWayHistory(1, wayHistory, status);
        client.readWayFull(1, dataset, status);
        client.readRelation(1, relation, status);
        client.readRelationVersion(1, 1, relation, status);
        client.readRelationHistory(1, relationHistory, status);
        client.readRelationFull(1, dataset, status);
        client.createChangeset(
            changesetRequest,
            "Bearer token",
            changesetId,
            status);
        client.readChangeset(1, changeset, status);
        client.updateChangeset(
            1,
            changesetRequest,
            "Bearer token",
            changeset,
            status);
        client.closeChangeset(1, "Bearer token", status);
        client.uploadChanges(
            1,
            changes,
            "Bearer token",
            uploadResult,
            status);
    }

    assert(client.server.valid);
}
