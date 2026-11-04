module app;

import osm;
import osm.upload;
import transport.source : MemorySource;

@safe void main()
{
    auto store = new OsmStore();

    OwnedNode node;
    node.id = 42;
    node.location = LocationView(48_000_000_000L, 16_000_000_000L);
    node.metadata.hasVersion = true;
    node.metadata.versionNumber = 7;

    StoreStatus storeStatus;
    OsmHandle handle;
    assert(store.add(node, handle, storeStatus));
    assert(store.remove(handle, storeStatus));

    OwnedChangeSequence uploaded;
    assert(store.collectChanges(uploaded, storeStatus));
    assert(uploaded.entries.length == 1);
    uploaded.entries[0].deleteIfUnused = true;
    assert(uploaded.setChangeset(99));

    enum responseXml =
        "<diffResult version=\"0.6\" generator=\"OpenStreetMap Server\">" ~
        "<node old_id=\"42\" new_id=\"42\" new_version=\"7\"/>" ~
        "</diffResult>";

    auto source = new MemorySource(cast(const(ubyte)[]) responseXml);

    UploadResult result;
    UploadResultReadStatus readStatus;
    assert(readUploadResult(
        source: source,
        result: result,
        status: readStatus));
    assert(readStatus.ok);
    assert(result.entries.length == 1);

    UploadResultEffect effect;
    assert(result.entries[0].effectFor(
        uploaded: uploaded.entries[0],
        effect: effect));
    assert(effect == UploadResultEffect.deleteRetained);

    assert(store.applyUploadResult(
        uploaded: uploaded,
        result: result,
        status: storeStatus));

    StoreNodeView restored;
    assert(store.node(handle, restored, storeStatus));
    assert(restored.state == StoreElementState.clean);
    assert(restored.metadata.versionNumber == 7);
}
