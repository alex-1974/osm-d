/**
 * Materialize a durable, loss-aware PBF document from an already-loaded file.
 *
 * This is the allocation boundary between Phase-3 borrowed decoding and the M4
 * owned model. The implementation deliberately favors correctness and contract
 * clarity over single-pass throughput: each element kind uses the existing
 * fully validating foreach reader boundary and copies only its own semantics.
 * M6 may later add direct PBF-to-store construction without changing this
 * document contract.
 *
 * Exact input bytes are captured before validation. Therefore malformed or
 * semantically unsupported input can still be retained for inspection even
 * when owned semantic materialization fails.
 *
 * This API consumes an already-loaded byte sequence. Filesystem, HTTP, range
 * access and sequential stream adaptation belong to the workspace
 * `transport-d` layer rather than this codec. See ADR 0019.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.document_reader;

import osm.io.pbf.blob : BlobView, decodeBlob;
import osm.io.pbf.blob_header : BlobKind;
import osm.io.pbf.decompress : BlobPayloadView;
import osm.io.pbf.document :
    PbfDocument,
    PbfHeader,
    PbfHeaderBBox;
import osm.io.pbf.error : PbfStatus;
import osm.io.pbf.framing :
    FileBlockView, FrameReadResult, readFileBlock;
import osm.io.pbf.header_block : HeaderBlockView, decodeHeaderBlock;
import osm.io.pbf.node_view : NodeView;
import osm.io.pbf.preservation_scan : scanPbfPreservation;
import osm.io.pbf.reader :
    PbfReadError,
    PbfReadStatus,
    PbfReader,
    PbfReaderWorkspace,
    decodeReaderBlobPayload,
    fromPbfFailure,
    readerFailure;
import osm.io.pbf.relation : RelationView;
import osm.io.pbf.way : WayView;
import osm.model.owned :
    OwnedDataset,
    OwnedMetadata,
    OwnedNode,
    OwnedRelation,
    OwnedRelationMember,
    OwnedTag,
    OwnedWay,
    OwnedWayNode,
    ownBytes;
import osm.raw.pbf : PbfRawFile;
import osm.view.metadata : MetadataView;
import osm.wire.cursor : WireCursor;

/**
 * Decode `input` into durable semantic values while retaining exact source.
 *
 * Params:
 *   input = Complete already-loaded PBF file bytes.
 *   document = Receives the durable document. Exact raw source is populated
 *     even when the function returns false.
 *   status = Existing high-level PBF read status.
 *
 * Returns:
 *   true only when the file is semantically readable and every Node, Way and
 *   Relation has been copied into the owned model. Unknown optional fields or
 *   features may still make `document.preservation.semanticRewriteSafe`
 *   false; that does not prevent read-only semantic materialization.
 *
 * Notes:
 *   Semantic materialization currently performs one complete traversal per OSM
 *   element kind. This avoids weakening the Phase-3 `@nogc` direct-sink
 *   callback contract merely to allocate an owned model.
 */
bool readPbfDocument(
    const(ubyte)[] input,
    out PbfDocument document,
    out PbfReadStatus status)
    @safe
{
    document = PbfDocument.init;
    document.preservation.source = PbfRawFile.capture(input);
    status = PbfReadStatus.init;

    PbfReaderWorkspace scanWorkspace;
    if (!scanPbfPreservation(
            input,
            scanWorkspace,
            document.preservation,
            status))
    {
        return false;
    }

    PbfHeader header;
    if (!readOwnedHeader(input, scanWorkspace, header, status))
        return false;

    OwnedDataset data;
    PbfReader reader;

    auto nodes = reader.nodes(input);
    foreach (scope ref NodeView value; nodes)
        data.nodes ~= ownNode(value);

    if (!nodes.completed || !nodes.status.ok)
    {
        status = nodes.status;
        return false;
    }

    auto ways = reader.ways(input);
    foreach (scope ref WayView value; ways)
        data.ways ~= ownWay(value);

    if (!ways.completed || !ways.status.ok)
    {
        status = ways.status;
        return false;
    }

    auto relations = reader.relations(input);
    foreach (scope ref RelationView value; relations)
        data.relations ~= ownRelation(value);

    if (!relations.completed || !relations.status.ok)
    {
        status = relations.status;
        return false;
    }

    document.header = header;
    document.data = data;
    status = PbfReadStatus.init;
    return true;
}

private bool readOwnedHeader(
    const(ubyte)[] input,
    ref PbfReaderWorkspace workspace,
    out PbfHeader result,
    out PbfReadStatus status)
    @safe
{
    result = PbfHeader.init;

    auto cursor = WireCursor(input);
    FileBlockView block;
    PbfStatus pbfStatus;
    const frame = readFileBlock(cursor, 0, block, pbfStatus);

    if (frame == FrameReadResult.error)
    {
        status = fromPbfFailure(0, 0, pbfStatus);
        return false;
    }

    if (frame == FrameReadResult.endOfInput)
    {
        status = readerFailure(PbfReadError.missingHeader, 0, 0);
        return false;
    }

    if (block.header.kind != BlobKind.osmHeader)
    {
        status = readerFailure(
            PbfReadError.dataBeforeHeader,
            0,
            block.offset);
        return false;
    }

    BlobView blob;
    if (!decodeBlob(block.blob, blob, pbfStatus))
    {
        status = fromPbfFailure(0, block.offset, pbfStatus);
        return false;
    }

    BlobPayloadView payload;
    if (!decodeReaderBlobPayload(blob, workspace, payload, pbfStatus))
    {
        status = fromPbfFailure(0, block.offset, pbfStatus);
        return false;
    }

    HeaderBlockView header;
    if (!decodeHeaderBlock(payload.bytes, header, pbfStatus))
    {
        status = fromPbfFailure(0, block.offset, pbfStatus);
        return false;
    }

    result.hasBBox = header.hasBBox;
    if (header.hasBBox)
    {
        result.bbox = PbfHeaderBBox(
            header.bbox.left,
            header.bbox.right,
            header.bbox.top,
            header.bbox.bottom);
    }

    auto required = header.requiredFeatures;
    while (!required.empty)
    {
        result.requiredFeatures ~= ownBytes(required.front.bytes);
        required.popFront();
    }

    auto optional = header.optionalFeatures;
    while (!optional.empty)
    {
        result.optionalFeatures ~= ownBytes(optional.front.bytes);
        optional.popFront();
    }

    result.hasWritingProgram = header.hasWritingProgram;
    if (header.hasWritingProgram)
        result.writingProgram = ownBytes(header.writingProgram);

    result.hasSource = header.hasSource;
    if (header.hasSource)
        result.source = ownBytes(header.source);

    result.hasReplicationTimestamp = header.hasReplicationTimestamp;
    result.replicationTimestamp = header.replicationTimestamp;

    result.hasReplicationSequenceNumber =
        header.hasReplicationSequenceNumber;
    result.replicationSequenceNumber =
        header.replicationSequenceNumber;

    result.hasReplicationBaseUrl = header.hasReplicationBaseUrl;
    if (header.hasReplicationBaseUrl)
        result.replicationBaseUrl = ownBytes(header.replicationBaseUrl);

    status = PbfReadStatus.init;
    return true;
}

private OwnedNode ownNode(scope ref NodeView value) @safe
{
    OwnedNode result;
    result.id = value.id;
    result.location = value.location;
    result.metadata = ownMetadata(value.metadata);
    result.tags = ownTags(value.tags);
    return result;
}

private OwnedWay ownWay(scope ref WayView value) @safe
{
    OwnedWay result;
    result.id = value.id;
    result.metadata = ownMetadata(value.metadata);
    result.tags = ownTags(value.tags);

    auto nodes = value.nodes;
    while (!nodes.empty)
    {
        const source = nodes.front;

        OwnedWayNode node;
        node.id = source.id;
        node.hasLocation = source.hasLocation;
        if (source.hasLocation)
            node.location = source.location;

        result.nodes ~= node;
        nodes.popFront();
    }

    return result;
}

private OwnedRelation ownRelation(scope ref RelationView value) @safe
{
    OwnedRelation result;
    result.id = value.id;
    result.metadata = ownMetadata(value.metadata);
    result.tags = ownTags(value.tags);

    auto members = value.members;
    while (!members.empty)
    {
        const source = members.front;

        OwnedRelationMember member;
        member.type = source.type;
        member.id = source.id;
        member.role = ownBytes(source.role);

        result.members ~= member;
        members.popFront();
    }

    return result;
}

private OwnedMetadata ownMetadata(MetadataView value) @safe
{
    OwnedMetadata result;

    result.hasVersion = value.hasVersion;
    if (value.hasVersion)
        result.versionNumber = value.versionNumber;

    result.hasTimestamp = value.hasTimestamp;
    if (value.hasTimestamp)
        result.timestampMilliseconds = value.timestampMilliseconds;

    result.hasChangeset = value.hasChangeset;
    if (value.hasChangeset)
        result.changesetId = value.changesetId;

    result.hasUserId = value.hasUserId;
    if (value.hasUserId)
        result.userId = value.userId;

    result.hasUsername = value.hasUsername;
    if (value.hasUsername)
        result.username = ownBytes(value.username);

    result.hasVisibility = value.hasVisibility;
    if (value.hasVisibility)
        result.visible = value.visible;

    return result;
}

private OwnedTag[] ownTags(Range)(return scope Range source) @safe
{
    OwnedTag[] result;

    while (!source.empty)
    {
        const tag = source.front;
        result ~= OwnedTag(
            ownBytes(tag.key),
            ownBytes(tag.value));
        source.popFront();
    }

    return result;
}


version(unittest)
{
    private void appendTestVarint(ref ubyte[] target, ulong value)
    {
        do
        {
            ubyte byteValue = cast(ubyte)(value & 0x7f);
            value >>= 7;
            if (value != 0)
                byteValue |= 0x80;
            target ~= byteValue;
        }
        while (value != 0);
    }

    private void appendTestVarintField(
        ref ubyte[] target,
        uint fieldNumber,
        ulong value)
    {
        appendTestVarint(target, cast(ulong)(fieldNumber << 3));
        appendTestVarint(target, value);
    }

    private void appendTestLengthField(
        ref ubyte[] target,
        uint fieldNumber,
        const(ubyte)[] value)
    {
        appendTestVarint(
            target,
            cast(ulong)((fieldNumber << 3) | 2));
        appendTestVarint(target, value.length);
        target ~= value;
    }

    private void appendTestFileBlock(
        ref ubyte[] target,
        string blockType,
        const(ubyte)[] payload)
    {
        ubyte[] blob;
        appendTestLengthField(blob, 1, payload);

        ubyte[] typeBytes;
        foreach (char c; blockType)
            typeBytes ~= cast(ubyte)c;

        ubyte[] header;
        appendTestLengthField(header, 1, typeBytes);
        appendTestVarintField(header, 3, blob.length);

        const length = cast(uint)header.length;
        target ~= cast(ubyte)(length >> 24);
        target ~= cast(ubyte)(length >> 16);
        target ~= cast(ubyte)(length >> 8);
        target ~= cast(ubyte)length;
        target ~= header;
        target ~= blob;
    }

    private ubyte[] makeTestPrimitiveBlock(
        const(ubyte)[] group = null)
    {
        ubyte[] table;
        appendTestLengthField(table, 1, null);

        ubyte[] block;
        appendTestLengthField(block, 1, table);
        if (group.length != 0)
            appendTestLengthField(block, 2, group);
        return block;
    }
}

unittest
{
    import osm.raw.pbf : PbfPreservationReason;

    // Unknown fixed32 Node field 15 is interleaved between known id/coordinates.
    // The semantic reader can still understand the node, but rewrite must be
    // blocked because the owned model cannot represent field 15.
    ubyte[] node;
    appendTestVarintField(node, 1, 2);
    node ~= 0x7d;
    node ~= [0xde, 0xad, 0xbe, 0xef];
    appendTestVarintField(node, 8, 0);
    appendTestVarintField(node, 9, 0);

    ubyte[] group;
    appendTestLengthField(group, 1, node);

    ubyte[] input;
    appendTestFileBlock(input, "OSMHeader", null);
    const data = makeTestPrimitiveBlock(group);
    appendTestFileBlock(input, "OSMData", data);

    PbfDocument document;
    PbfReadStatus status;
    assert(readPbfDocument(input, document, status));
    assert(status.ok);
    assert(document.data.nodes.length == 1);
    assert(document.data.nodes[0].id == 1);
    assert(document.preservation.reason ==
        PbfPreservationReason.unknownField);
    assert(!document.preservation.semanticRewriteSafe);
    assert(document.preservation.source.bytes == input);
}

unittest
{
    import osm.raw.pbf : PbfPreservationReason;

    ubyte[] feature;
    foreach (char c; "Vendor-Optional-X")
        feature ~= cast(ubyte)c;

    ubyte[] headerPayload;
    appendTestLengthField(headerPayload, 5, feature);

    ubyte[] input;
    appendTestFileBlock(input, "OSMHeader", headerPayload);

    PbfDocument document;
    PbfReadStatus status;
    assert(readPbfDocument(input, document, status));
    assert(document.data.empty);
    assert(document.header.optionalFeatures.length == 1);
    assert(document.header.optionalFeatures[0] == feature);
    assert(document.preservation.reason ==
        PbfPreservationReason.unknownOptionalFeature);
    assert(document.preservation.source.bytes == input);
}

unittest
{
    ubyte[] input;
    appendTestFileBlock(input, "OSMHeader", null);

    PbfDocument document;
    PbfReadStatus status;
    assert(readPbfDocument(input, document, status));
    assert(status.ok);
    assert(document.data.empty);
    assert(document.preservation.semanticRewriteSafe);
    assert(document.preservation.source.bytes == input);
}
