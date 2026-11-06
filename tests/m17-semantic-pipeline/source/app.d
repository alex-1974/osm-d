module app;

import osm :
    ElementType,
    LocationView,
    OsmHandle,
    OsmStore,
    OwnedChangeSequence,
    OwnedNode,
    StoreNodeView,
    StoreStatus,
    ownBytes,
    OwnedTag;
import osm.capabilities :
    ApiCapabilitiesReadStatus,
    EditingApiCapabilitiesDocument,
    readEditingApiCapabilities;
import osm.changeset :
    ChangesetReadStatus,
    ChangesetTagRequest,
    ChangesetWriteStatus,
    OwnedChangeset,
    readChangeset,
    writeChangesetTagRequest;
import osm.compare : sameChangeSemantics;
import osm.osmchange :
    OsmChangeDocument,
    OsmChangeReadStatus,
    OsmChangeWriteStatus,
    OsmChangeWriter,
    readOsmChangeDocument;
import osm.upload :
    UploadResult,
    UploadResultReadStatus,
    readUploadResult;
import osm.validate :
    UploadValidationIssue,
    validateUploadChanges;
import transport.source :
    MemorySink,
    MemorySource;

@safe void main()
{
    const capabilities = readCapabilities();
    const changeset = readOpenChangeset();

    // Qualify the tag-only create/update request shape independently of HTTP.
    ChangesetTagRequest request;
    request.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"created_by"),
        ownBytes(cast(const(ubyte)[])"osm-d M17 qualification"));
    request.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"comment"),
        ownBytes(cast(const(ubyte)[])"qualify semantic editing pipeline"));

    auto requestSink = new MemorySink();
    ChangesetWriteStatus requestStatus;
    assert(writeChangesetTagRequest(request, requestSink, requestStatus));
    assert(requestStatus.ok);
    assert(requestSink.data.length > 0);

    auto store = new OsmStore();
    StoreStatus storeStatus;

    // Established object that will be modified.
    OwnedNode modifiedBaseline;
    modifiedBaseline.id = 42;
    modifiedBaseline.location =
        LocationView(48_200_000_000L, 16_300_000_000L);
    modifiedBaseline.metadata.hasVersion = true;
    modifiedBaseline.metadata.versionNumber = 3;
    modifiedBaseline.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"amenity"),
        ownBytes(cast(const(ubyte)[])"bench"));

    OsmHandle modifiedHandle;
    assert(store.add(modifiedBaseline, modifiedHandle, storeStatus));
    assert(storeStatus.ok);

    // Established object that will be deleted.
    OwnedNode deletedBaseline;
    deletedBaseline.id = 43;
    deletedBaseline.location =
        LocationView(48_201_000_000L, 16_301_000_000L);
    deletedBaseline.metadata.hasVersion = true;
    deletedBaseline.metadata.versionNumber = 5;

    OsmHandle deletedHandle;
    assert(store.add(deletedBaseline, deletedHandle, storeStatus));

    // Local object that will be created.
    OwnedNode created;
    created.id = -1;
    created.location =
        LocationView(48_202_000_000L, 16_302_000_000L);
    created.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"highway"),
        ownBytes(cast(const(ubyte)[])"street_lamp"));

    OsmHandle createdHandle;
    assert(store.add(created, createdHandle, storeStatus));

    OwnedNode modified;
    assert(store.copyNode(modifiedHandle, modified, storeStatus));
    modified.location =
        LocationView(48_200_100_000L, 16_300_100_000L);
    modified.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"backrest"),
        ownBytes(cast(const(ubyte)[])"yes"));
    assert(store.replace(modifiedHandle, modified, storeStatus));

    assert(store.remove(deletedHandle, storeStatus));

    OwnedChangeSequence uploaded;
    assert(store.collectChanges(uploaded, storeStatus));
    assert(uploaded.entries.length == 3);

    // Store ordering is upload-oriented: creates, modifies, then deletes.
    assert(uploaded.entries[0].id == -1);
    assert(uploaded.entries[1].id == 42);
    assert(uploaded.entries[2].id == 43);

    assert(changeset.hasId && changeset.id > 0);
    assert(uploaded.setChangeset(changeset.id));

    foreach (ref const entry; uploaded.entries)
    {
        assert(entry.metadata.hasChangeset);
        assert(entry.metadata.changesetId == changeset.id);
    }

    UploadValidationIssue validation;
    assert(validateUploadChanges(
        uploaded,
        capabilities.capabilities.validationProfile,
        validation));
    assert(validation.ok);

    auto osmChangeSink = new MemorySink();
    OsmChangeWriter writer;
    OsmChangeWriteStatus writeStatus;
    assert(writer.writeChanges(uploaded, osmChangeSink, writeStatus));
    assert(writeStatus.ok);

    // Re-read the exact request bytes to prove the semantic sequence survives
    // the osmChange codec boundary before it would be handed to HTTP.
    auto osmChangeSource = new MemorySource(osmChangeSink.data);
    OsmChangeDocument encoded;
    OsmChangeReadStatus changeReadStatus;
    assert(readOsmChangeDocument(
        osmChangeSource,
        encoded,
        changeReadStatus));
    assert(changeReadStatus.ok);
    assert(sameChangeSemantics(uploaded, encoded.changes));

    // Deterministic successful server acknowledgement. The result is parsed
    // through the existing diffResult codec rather than synthesized directly.
    enum diffResultXml =
        "<diffResult version=\"0.6\" generator=\"OpenStreetMap Server\">" ~
        "<node old_id=\"-1\" new_id=\"1001\" new_version=\"1\"/>" ~
        "<node old_id=\"42\" new_id=\"42\" new_version=\"4\"/>" ~
        "<node old_id=\"43\"/>" ~
        "</diffResult>";

    auto resultSource =
        new MemorySource(cast(const(ubyte)[]) diffResultXml);
    UploadResult result;
    UploadResultReadStatus resultStatus;
    assert(readUploadResult(resultSource, result, resultStatus));
    assert(resultStatus.ok);
    assert(result.entries.length == uploaded.entries.length);

    assert(store.applyUploadResult(uploaded, result, storeStatus));
    assert(storeStatus.ok);

    // Created object keeps its stable handle but receives server identity.
    StoreNodeView createdView;
    assert(store.node(1001, createdView, storeStatus));
    assert(createdView.handle == createdHandle);
    assert(createdView.metadata.hasVersion);
    assert(createdView.metadata.versionNumber == 1);
    assert(createdView.metadata.hasChangeset);
    assert(createdView.metadata.changesetId == changeset.id);

    // Modified object remains present at its established ID with new version.
    StoreNodeView modifiedView;
    assert(store.node(42, modifiedView, storeStatus));
    assert(modifiedView.handle == modifiedHandle);
    assert(modifiedView.metadata.hasVersion);
    assert(modifiedView.metadata.versionNumber == 4);
    assert(modifiedView.metadata.hasChangeset);
    assert(modifiedView.metadata.changesetId == changeset.id);

    // Successful delete removes the established identity.
    OsmHandle shouldBeMissing;
    assert(!store.find(ElementType.node, 43, shouldBeMissing));

    OwnedChangeSequence remaining;
    assert(store.collectChanges(remaining, storeStatus));
    assert(remaining.empty);
}

private EditingApiCapabilitiesDocument readCapabilities() @safe
{
    enum xml =
        "<osm version=\"0.6\" generator=\"OpenStreetMap server\">" ~
        "<api>" ~
        "<version minimum=\"0.6\" maximum=\"0.6\"/>" ~
        "<waynodes maximum=\"2000\"/>" ~
        "<relationmembers maximum=\"32000\"/>" ~
        "<changesets maximum_elements=\"10000\"/>" ~
        "<status database=\"online\" api=\"online\" gpx=\"online\"/>" ~
        "</api></osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    EditingApiCapabilitiesDocument document;
    ApiCapabilitiesReadStatus status;
    assert(readEditingApiCapabilities(source, document, status));
    assert(status.ok);
    return document;
}

private OwnedChangeset readOpenChangeset() @safe
{
    enum xml =
        "<osm version=\"0.6\" generator=\"OpenStreetMap server\">" ~
        "<changeset id=\"7001\" " ~
        "created_at=\"2026-11-06T10:00:00Z\" open=\"true\" " ~
        "user=\"qualification\" uid=\"123\" " ~
        "comments_count=\"0\" changes_count=\"0\" " ~
        "created_count=\"0\" modified_count=\"0\" deleted_count=\"0\">" ~
        "<tag k=\"created_by\" v=\"osm-d M17 qualification\"/>" ~
        "<tag k=\"comment\" v=\"qualify semantic editing pipeline\"/>" ~
        "</changeset></osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);
    OwnedChangeset changeset;
    ChangesetReadStatus status;
    assert(readChangeset(source, changeset, status));
    assert(status.ok);
    assert(changeset.hasOpenState && changeset.open);
    return changeset;
}
