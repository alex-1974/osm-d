module app;

import osm.changeset;
import osm.model.owned :
    OwnedTag,
    ownBytes;
import transport.source :
    MemorySink,
    MemorySource;

@safe void main()
{
    ChangesetTagRequest request;
    request.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[]) "created_by"),
        ownBytes(cast(const(ubyte)[]) "osm-d"));
    request.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[]) "comment"),
        ownBytes(cast(const(ubyte)[]) "consumer probe"));

    auto sink = new MemorySink();
    ChangesetWriteStatus writeStatus;
    assert(writeChangesetTagRequest(request, sink, writeStatus));
    assert(writeStatus.ok);

    enum response =
        "<osm version=\"0.6\" generator=\"OpenStreetMap server\">" ~
        "<changeset id=\"42\" created_at=\"2026-02-10T12:00:00Z\" " ~
        "open=\"true\" user=\"mapper\" uid=\"7\" " ~
        "comments_count=\"0\" changes_count=\"0\" " ~
        "created_count=\"0\" modified_count=\"0\" deleted_count=\"0\">" ~
        "<tag k=\"comment\" v=\"consumer probe\"/>" ~
        "</changeset></osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) response);
    OwnedChangeset changeset;
    ChangesetReadStatus readStatus;
    assert(readChangeset(source, changeset, readStatus));
    assert(readStatus.ok);
    assert(changeset.hasId && changeset.id == 42);
    assert(changeset.hasOpenState && changeset.open);
    assert(changeset.hasCreatedCount && changeset.createdCount == 0);
    assert(!changeset.hasBounds);
    assert(!changeset.hasDiscussion);
}
