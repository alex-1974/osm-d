
module app;

import osm.api;
import transport.buffer : SegmentedByteBuffer;
import transport.exchange :
    HttpExchange,
    HttpExchangeError,
    HttpExchangeErrorKind,
    HttpExchangeResult,
    HttpMethod,
    HttpRequest,
    HttpResponse;

private final class FakeExchange : HttpExchange
{
    HttpResponse response;
    bool failTransport;

    HttpMethod lastMethod;
    string lastUrl;
    string lastAccept;
    string lastContentType;
    bool sawAuthorization;
    size_t lastBodyLength;

    void succeed(ushort status, string bodyText, string contentType = "application/xml")
        @safe
    {
        failTransport = false;
        auto body = new SegmentedByteBuffer(7, 2 * 1024 * 1024);
        if (bodyText.length)
            assert(body.write(cast(const(ubyte)[]) bodyText).hasValue);

        string[string] headers;
        if (contentType.length)
            headers["content-type"] = contentType;

        response = HttpResponse(
            status,
            status == 200 ? "OK" : "Error",
            headers,
            "https://example.test/api/0.6",
            body);
    }

    void fail() @safe
    {
        failTransport = true;
    }

    HttpExchangeResult exchange(scope const ref HttpRequest request) @safe
    {
        lastMethod = request.method;
        lastUrl = request.url.idup;
        lastAccept = request.headers.get("Accept", "").idup;
        lastContentType = request.headers.get("Content-Type", "").idup;
        sawAuthorization =
            ("Authorization" in request.sensitiveHeaders) !is null;
        lastBodyLength =
            request.body is null ? 0 : request.body.length;

        if (failTransport)
            return HttpExchangeResult.failure(
                HttpExchangeError(HttpExchangeErrorKind.transportFailure));

        return HttpExchangeResult.success(response);
    }
}

@safe void main()
{
    auto fake = new FakeExchange();
    auto client = new EditingApiClient(
        EditingApiServer("https://example.test/api/0.6/"),
        fake);

    qualifyDiscovery(client, fake);
    qualifyElementReads(client, fake);
    qualifyChangesets(client, fake);
    qualifyStatusSeparation(client, fake);
}

private void qualifyDiscovery(EditingApiClient client, FakeExchange fake) @safe
{
    enum capabilitiesXml =
        "<osm version=\"0.6\" generator=\"OpenStreetMap server\">" ~
        "<api>" ~
        "<version minimum=\"0.6\" maximum=\"0.6\"/>" ~
        "<waynodes maximum=\"2000\"/>" ~
        "<relationmembers maximum=\"32000\"/>" ~
        "<changesets maximum_elements=\"10000\"/>" ~
        "<status database=\"online\" api=\"online\" gpx=\"online\"/>" ~
        "</api></osm>";

    fake.succeed(200, capabilitiesXml);

    EditingApiCapabilitiesDocument capabilities;
    EditingApiStatus status;
    assert(client.readCapabilities(capabilities, status));
    assert(status.ok && status.httpStatus == 200);
    assert(fake.lastMethod == HttpMethod.get);
    assert(fake.lastUrl ==
        "https://example.test/api/0.6/capabilities");
    assert(capabilities.capabilities.validationProfile.maximumWayNodes == 2000);

    enum permissionsXml =
        "<osm version=\"0.6\" generator=\"OpenStreetMap server\">" ~
        "<permissions>" ~
        "<permission name=\"allow_read_prefs\"/>" ~
        "<permission name=\"allow_write_api\"/>" ~
        "</permissions></osm>";

    fake.succeed(200, permissionsXml);
    EditingApiPermissions permissions;
    assert(client.readPermissions(
        permissions,
        status,
        "Bearer qualification-token"));
    assert(status.ok);
    assert(fake.lastMethod == HttpMethod.get);
    assert(fake.lastUrl ==
        "https://example.test/api/0.6/permissions");
    assert(fake.sawAuthorization);
    assert(permissions.canWriteMap);
    assert(permissions.allows("allow_read_prefs"));
}

private void qualifyElementReads(EditingApiClient client, FakeExchange fake) @safe
{
    EditingApiStatus status;

    fake.succeed(200, import("editing-api/node-current.xml"));
    OwnedNode node;
    assert(client.readNode(101, node, status));
    assert(node.id == 101);
    assert(fake.lastUrl ==
        "https://example.test/api/0.6/node/101");

    fake.succeed(200, import("editing-api/node-version.xml"));
    assert(client.readNodeVersion(101, 2, node, status));
    assert(node.metadata.versionNumber == 2);
    assert(fake.lastUrl ==
        "https://example.test/api/0.6/node/101/2");

    fake.succeed(200, import("editing-api/node-history.xml"));
    OwnedNode[] nodes;
    assert(client.readNodeHistory(101, nodes, status));
    assert(nodes.length == 3);
    assert(fake.lastUrl ==
        "https://example.test/api/0.6/node/101/history");

    fake.succeed(200, import("editing-api/way-current.xml"));
    OwnedWay way;
    assert(client.readWay(201, way, status));
    assert(way.id == 201);

    fake.succeed(200, import("editing-api/way-version.xml"));
    assert(client.readWayVersion(201, 2, way, status));
    assert(way.metadata.versionNumber == 2);

    fake.succeed(200, import("editing-api/way-history.xml"));
    OwnedWay[] ways;
    assert(client.readWayHistory(201, ways, status));
    assert(ways.length == 3);

    fake.succeed(200, import("editing-api/way-full.xml"));
    OwnedDataset dataset;
    assert(client.readWayFull(201, dataset, status));
    assert(dataset.ways.length == 1);
    assert(dataset.nodes.length == 2);
    assert(fake.lastUrl ==
        "https://example.test/api/0.6/way/201/full");

    fake.succeed(200, import("editing-api/relation-current.xml"));
    OwnedRelation relation;
    assert(client.readRelation(301, relation, status));
    assert(relation.id == 301);

    fake.succeed(200, import("editing-api/relation-version.xml"));
    assert(client.readRelationVersion(301, 3, relation, status));
    assert(relation.metadata.versionNumber == 3);

    fake.succeed(200, import("editing-api/relation-history.xml"));
    OwnedRelation[] relations;
    assert(client.readRelationHistory(301, relations, status));
    assert(relations.length == 3);

    fake.succeed(200, import("editing-api/relation-full.xml"));
    assert(client.readRelationFull(301, dataset, status));
    assert(dataset.relations.length == 2);
    assert(fake.lastUrl ==
        "https://example.test/api/0.6/relation/301/full");
}

private void qualifyChangesets(EditingApiClient client, FakeExchange fake) @safe
{
    EditingApiStatus status;
    ChangesetTagRequest request;
    request.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"created_by"),
        ownBytes(cast(const(ubyte)[])"osm-d M17 qualification"));
    request.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"comment"),
        ownBytes(cast(const(ubyte)[])"protocol client qualification"));

    fake.succeed(200, "1001\n", "text/plain");
    ChangesetId changesetId;
    assert(client.createChangeset(
        request,
        "Bearer qualification-token",
        changesetId,
        status));
    assert(changesetId == 1001);
    assert(fake.lastMethod == HttpMethod.put);
    assert(fake.lastUrl ==
        "https://example.test/api/0.6/changeset/create");
    assert(fake.sawAuthorization);
    assert(fake.lastBodyLength > 0);
    assert(fake.lastContentType == "text/xml; charset=utf-8");

    fake.succeed(200, import("changeset/current-open.xml"));
    OwnedChangeset changeset;
    assert(client.readChangeset(1001, changeset, status));
    assert(changeset.hasId && changeset.id == 1001);

    fake.succeed(200, import("changeset/current-open.xml"));
    assert(client.updateChangeset(
        1001,
        request,
        "Bearer qualification-token",
        changeset,
        status));
    assert(fake.lastMethod == HttpMethod.put);
    assert(fake.lastUrl ==
        "https://example.test/api/0.6/changeset/1001");
    assert(fake.lastBodyLength > 0);

    fake.succeed(200, "");
    assert(client.closeChangeset(
        1001,
        "Bearer qualification-token",
        status));
    assert(fake.lastMethod == HttpMethod.put);
    assert(fake.lastUrl ==
        "https://example.test/api/0.6/changeset/1001/close");

    OwnedNode created;
    created.id = -1;
    created.location = LocationView(
        48_200_000_000L,
        16_300_000_000L);

    OwnedChangeSequence changes;
    changes.entries ~=
        OwnedChangeEntry.fromNode(ChangeAction.create, created);
    assert(changes.setChangeset(1001));

    enum diffResultXml =
        "<diffResult version=\"0.6\" generator=\"OpenStreetMap Server\">" ~
        "<node old_id=\"-1\" new_id=\"1001\" new_version=\"1\"/>" ~
        "</diffResult>";

    fake.succeed(200, diffResultXml);
    UploadResult result;
    assert(client.uploadChanges(
        1001,
        changes,
        "Bearer qualification-token",
        result,
        status));
    assert(result.entries.length == 1);
    assert(fake.lastMethod == HttpMethod.post);
    assert(fake.lastUrl ==
        "https://example.test/api/0.6/changeset/1001/upload");
    assert(fake.lastBodyLength > 0);
}

private void qualifyStatusSeparation(EditingApiClient client, FakeExchange fake) @safe
{
    EditingApiStatus status;

    fake.succeed(409, "The changeset was closed.", "text/plain");
    assert(!client.closeChangeset(
        1001,
        "Bearer qualification-token",
        status));
    assert(status.failure == EditingApiFailure.http);
    assert(status.hasHttpStatus && status.httpStatus == 409);
    assert(status.serverError == EditingApiServerError.conflict);
    assert(!status.hasTransportError);

    fake.succeed(412, "Precondition failed.", "text/plain");
    assert(!client.closeChangeset(
        1001,
        "Bearer qualification-token",
        status));
    assert(status.failure == EditingApiFailure.http);
    assert(status.serverError ==
        EditingApiServerError.preconditionFailed);

    fake.fail();
    OwnedNode node;
    assert(!client.readNode(101, node, status));
    assert(status.failure == EditingApiFailure.transport);
    assert(status.hasTransportError);
    assert(status.transportError ==
        HttpExchangeErrorKind.transportFailure);
    assert(!status.hasHttpStatus);

    fake.succeed(200, "<osm version=\"0.6\"><node");
    assert(!client.readNode(101, node, status));
    assert(status.failure == EditingApiFailure.responseDecoding);
    assert(status.hasHttpStatus && status.httpStatus == 200);

    fake.succeed(429, "Rate limited.", "text/plain");
    assert(!client.closeChangeset(
        1001,
        "Bearer qualification-token",
        status));
    assert(status.failure == EditingApiFailure.http);
    assert(status.serverError == EditingApiServerError.rateLimited);

    fake.succeed(200, "");
    assert(!client.closeChangeset(
        0,
        "Bearer qualification-token",
        status));
    assert(status.failure == EditingApiFailure.localValidation);

    assert(!client.closeChangeset(
        1001,
        "",
        status));
    assert(status.failure == EditingApiFailure.localValidation);
}
