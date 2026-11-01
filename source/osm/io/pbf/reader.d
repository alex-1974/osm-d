/**
 * Consumer-facing orchestration for complete in-memory OSMPBF files.
 *
 * PbfReader composes the existing framing, Blob, HeaderBlock, PrimitiveBlock,
 * PrimitiveGroup, and element decoders into one semantic read operation. It
 * does not materialize an owned OSM model. Element views remain borrowed from
 * the input or reusable workspace and are valid only for the duration of the
 * synchronous callback that receives them.
 *
 * PbfReaderWorkspace owns reusable scratch storage used for decompression,
 * StringTable indexing, and regular-Way preflight plans. The first read may
 * grow that storage through the D garbage collector; subsequent reads reuse
 * the retained capacity whenever it is sufficient.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-01
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.reader;

import osm.io.pbf.blob : BlobView, decodeBlob;
import osm.io.pbf.blob_header : BlobKind;
import osm.io.pbf.decompress :
    BlobPayloadView,
    decodeBlobPayloadInto,
    requiredOutputSize;
import osm.io.pbf.dense_nodes :
    DenseNodeDecodeSummary,
    DenseNodeView,
    decodeDenseNodes;
import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.features :
    HeaderFeatureAssessment,
    HeaderFeatureSupport,
    validateRequiredFeatures;
import osm.io.pbf.framing :
    FileBlockView,
    FrameReadResult,
    readFileBlock;
import osm.io.pbf.header_block : HeaderBlockView, decodeHeaderBlock;
import osm.io.pbf.node : NodeDecodeSummary, NodeView, decodeNodes;
import osm.io.pbf.primitive_block :
    PrimitiveBlockLayout,
    decodePrimitiveBlockLayout;
import osm.io.pbf.primitive_group :
    PrimitiveGroupLayout,
    decodePrimitiveGroupLayout;
import osm.io.pbf.relation :
    RelationDecodeSummary,
    RelationView,
    decodeRelations;
import osm.io.pbf.string_table :
    StringRef,
    StringTableView,
    buildStringTableView;
import osm.io.pbf.way :
    WayDecodePlan,
    WayDecodeSummary,
    WayView,
    decodeWaysWithWorkspace;
import osm.wire.cursor : WireCursor;

/** High-level category of a complete-file PBF read failure. */
enum PbfReadError : ubyte
{
    /// No failure occurred.
    none,
    /// Encoded input is malformed or violates a validated PBF/OSM invariant.
    malformedInput,
    /// A required HeaderBlock feature is not supported by this reader.
    unsupportedFeature,
    /// The Blob uses a compression representation without a supported backend.
    unsupportedCompression,
    /// OSMData appeared before the required leading OSMHeader block.
    dataBeforeHeader,
    /// A second OSMHeader appeared after a header or data block.
    duplicateHeader,
    /// The file ended without a valid OSMHeader block.
    missingHeader,
    /// A file block uses a type other than OSMHeader or OSMData.
    unsupportedBlockType,
    /// A legacy ChangeSet primitive occurred in an OSMData PrimitiveGroup.
    unsupportedChangeSet,
}

/** Processing stage associated with a PbfReadStatus diagnostic. */
enum PbfReadStage : ubyte
{
    /// No stage is associated with a successful status.
    none,
    /// File-level ordering or block-kind validation.
    file,
    /// File-block framing and BlobHeader decoding.
    framing,
    /// Blob protobuf validation.
    blob,
    /// Blob decompression/materialization.
    payload,
    /// HeaderBlock decoding.
    header,
    /// Required-feature compatibility validation.
    features,
    /// PrimitiveBlock decoding.
    primitiveBlock,
    /// StringTable indexing.
    stringTable,
    /// PrimitiveGroup decoding or file-level group policy.
    primitiveGroup,
    /// DenseNodes semantic decoding.
    denseNodes,
    /// Regular Node semantic decoding.
    node,
    /// Regular Way semantic decoding.
    way,
    /// Regular Relation semantic decoding.
    relation,
}

/**
 * Diagnostic for one complete-file PBF read.
 *
 * error is the stable high-level category. detail preserves the lower-level
 * PbfError when the failure came from an existing PBF decoder. blockSequence
 * and blockOffset identify the enclosing file block when available.
 * detailOffset is relative to the input of stage; for framing failures it is
 * an offset in the complete file buffer.
 *
 * PbfReadStatus.init is the successful status.
 */
struct PbfReadStatus
{
    /// High-level failure category; PbfReadError.none denotes success.
    PbfReadError error = PbfReadError.none;
    /// Reader stage that detected the failure.
    PbfReadStage stage = PbfReadStage.none;
    /// Zero-based file-block sequence being processed.
    ulong blockSequence;
    /// Offset of the enclosing file block in the complete input buffer.
    size_t blockOffset;
    /// Lower-level PBF error, or PbfError.none for reader-level failures.
    PbfError detail = PbfError.none;
    /// Offset reported by the lower-level decoder for its stage input.
    size_t detailOffset;
    /// Protobuf field number reported by the lower-level decoder, if any.
    uint detailFieldNumber;

    /** Returns true when no read error has occurred. */
    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == PbfReadError.none;
    }
}

/**
 * Counts from one successfully completed PbfReader.read operation.
 *
 * The fields are contractually valid only after read returns true.
 */
struct PbfReadSummary
{
    /// Number of validated OSMHeader file blocks.
    ulong headerBlocks;
    /// Number of validated OSMData file blocks.
    ulong dataBlocks;
    /// Number of decoded PrimitiveGroup occurrences.
    ulong primitiveGroups;
    /// Number of decoded OSM nodes, dense and regular combined.
    ulong nodes;
    /// Number of decoded OSM ways.
    ulong ways;
    /// Number of decoded OSM relations.
    ulong relations;
    /// Number of decoded element tags.
    ulong tags;
}

/**
 * Reusable scratch storage for PbfReader.
 *
 * The representation is intentionally private. Consumers own the workspace as
 * an ordinary value and may retain it across reads to reuse previously grown
 * storage. PbfReaderWorkspace.init is a valid empty workspace.
 */
struct PbfReaderWorkspace
{
private:
    ubyte[] decompressionBuffer;
    StringRef[] stringRefs;
    WayDecodePlan[] wayPlans;
}

/**
 * Whole-buffer OSMPBF reader.
 *
 * The reader is stateless; reusable allocation belongs to PbfReaderWorkspace.
 * PbfReader.init is therefore a valid reader.
 *
 * Handler callbacks are discovered statically by name. A handler may omit
 * node, way, or relation entirely when that element kind is not needed. When a
 * node callback is present it must accept both regular NodeView and
 * DenseNodeView, normally with one templated node method. Callbacks execute
 * synchronously and must satisfy @safe nothrow @nogc. Borrowed views must not
 * escape the callback.
 */
struct PbfReader
{
    /**
     * Decode one complete already-loaded .osm.pbf byte sequence.
     *
     * Params:
     *   input = Complete encoded PBF file bytes. They must remain valid for the
     *     duration of this call.
     *   workspace = Caller-owned reusable scratch storage. The first read may
     *     grow its internal arrays; later reads reuse retained capacity.
     *   handler = Consumer receiving any implemented node/way/relation
     *     callbacks synchronously.
     *   summary = Receives complete entity/block counts on success.
     *   status = Receives success or a high-level error plus diagnostic detail.
     *
     * Returns:
     *   true after the complete file has been validated and decoded; false on
     *   the first failure.
     *
     * Notes:
     *   This function does not materialize an owned OSM model. It may allocate
     *   only when reusable workspace must grow. Element decoder hot paths stay
     *   allocation-free and statically dispatched.
     */
    bool read(Handler)(
        const(ubyte)[] input,
        ref PbfReaderWorkspace workspace,
        ref Handler handler,
        out PbfReadSummary summary,
        out PbfReadStatus status)
        @safe
    {
        summary = PbfReadSummary.init;
        status = PbfReadStatus.init;

        auto cursor = WireCursor(input);
        SemanticSink!Handler sink = SemanticSink!Handler(handler);
        bool sawHeader;
        bool sawData;
        ulong sequence;

        while (true)
        {
            const blockOffset = cursor.offset;
            FileBlockView fileBlock;
            PbfStatus pbfStatus;
            const frameResult =
                readFileBlock(cursor, sequence, fileBlock, pbfStatus);

            final switch (frameResult)
            {
                case FrameReadResult.endOfInput:
                    break;

                case FrameReadResult.error:
                    status = fromPbfFailure(
                        PbfReadStage.framing,
                        sequence,
                        blockOffset,
                        pbfStatus);
                    return false;

                case FrameReadResult.block:
                    BlobView blob;
                    if (!decodeBlob(fileBlock.blob, blob, pbfStatus))
                    {
                        status = fromPbfFailure(
                            PbfReadStage.blob,
                            sequence,
                            fileBlock.offset,
                            pbfStatus);
                        return false;
                    }

                    const outputSize = requiredOutputSize(blob);
                    if (workspace.decompressionBuffer.length < outputSize)
                        workspace.decompressionBuffer.length = outputSize;

                    BlobPayloadView payload;
                    if (!decodeBlobPayloadInto(
                            blob,
                            workspace.decompressionBuffer,
                            payload,
                            pbfStatus))
                    {
                        status = fromPbfFailure(
                            PbfReadStage.payload,
                            sequence,
                            fileBlock.offset,
                            pbfStatus);
                        return false;
                    }

                    final switch (fileBlock.header.kind)
                    {
                        case BlobKind.osmHeader:
                            if (sawHeader || sawData)
                            {
                                status = readerFailure(
                                    PbfReadError.duplicateHeader,
                                    PbfReadStage.file,
                                    sequence,
                                    fileBlock.offset);
                                return false;
                            }

                            HeaderBlockView header;
                            if (!decodeHeaderBlock(
                                    payload.bytes,
                                    header,
                                    pbfStatus))
                            {
                                status = fromPbfFailure(
                                    PbfReadStage.header,
                                    sequence,
                                    fileBlock.offset,
                                    pbfStatus);
                                return false;
                            }

                            HeaderFeatureAssessment assessment;
                            if (!validateRequiredFeatures(
                                    header,
                                    HeaderFeatureSupport.allKnown(),
                                    assessment,
                                    pbfStatus))
                            {
                                status = fromPbfFailure(
                                    PbfReadStage.features,
                                    sequence,
                                    fileBlock.offset,
                                    pbfStatus);
                                return false;
                            }

                            sawHeader = true;
                            ++summary.headerBlocks;
                            break;

                        case BlobKind.osmData:
                            if (!sawHeader)
                            {
                                status = readerFailure(
                                    PbfReadError.dataBeforeHeader,
                                    PbfReadStage.file,
                                    sequence,
                                    fileBlock.offset);
                                return false;
                            }

                            sawData = true;
                            if (!decodeDataBlock(
                                    payload.bytes,
                                    workspace,
                                    sink,
                                    summary,
                                    sequence,
                                    fileBlock.offset,
                                    status))
                            {
                                return false;
                            }
                            break;

                        case BlobKind.unknown:
                            status = readerFailure(
                                PbfReadError.unsupportedBlockType,
                                PbfReadStage.file,
                                sequence,
                                fileBlock.offset);
                            return false;
                    }

                    ++sequence;
                    continue;
            }

            break;
        }

        if (!sawHeader)
        {
            status = readerFailure(
                PbfReadError.missingHeader,
                PbfReadStage.file,
                sequence,
                input.length);
            return false;
        }

        return true;
    }
}

private bool decodeDataBlock(Sink)(
    const(ubyte)[] payloadBytes,
    ref PbfReaderWorkspace workspace,
    ref Sink sink,
    ref PbfReadSummary summary,
    ulong sequence,
    size_t fileBlockOffset,
    out PbfReadStatus readStatus)
    @safe
{
    PbfStatus status;

    PrimitiveBlockLayout block;
    if (!decodePrimitiveBlockLayout(payloadBytes, block, status))
    {
        readStatus = fromPbfFailure(
            PbfReadStage.primitiveBlock,
            sequence,
            fileBlockOffset,
            status);
        return false;
    }

    if (workspace.stringRefs.length < block.stringCount)
        workspace.stringRefs.length = block.stringCount;

    StringTableView table;
    if (!buildStringTableView(
            block,
            workspace.stringRefs[0 .. block.stringCount],
            table,
            status))
    {
        readStatus = fromPbfFailure(
            PbfReadStage.stringTable,
            sequence,
            fileBlockOffset,
            status);
        return false;
    }

    auto groups = block.primitiveGroups;
    while (!groups.empty)
    {
        const groupRef = groups.front;
        groups.popFront();

        PrimitiveGroupLayout group;
        if (!decodePrimitiveGroupLayout(groupRef.bytes, group, status))
        {
            readStatus = fromPbfFailure(
                PbfReadStage.primitiveGroup,
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (group.changeSetOccurrences != 0)
        {
            readStatus = readerFailure(
                PbfReadError.unsupportedChangeSet,
                PbfReadStage.primitiveGroup,
                sequence,
                fileBlockOffset);
            return false;
        }

        DenseNodeDecodeSummary denseSummary;
        if (!decodeDenseNodes(
                block,
                group,
                table,
                sink,
                denseSummary,
                status))
        {
            readStatus = fromPbfFailure(
                PbfReadStage.denseNodes,
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        NodeDecodeSummary nodeSummary;
        if (!decodeNodes(
                block,
                group,
                table,
                sink,
                nodeSummary,
                status))
        {
            readStatus = fromPbfFailure(
                PbfReadStage.node,
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (workspace.wayPlans.length < group.wayOccurrences)
            workspace.wayPlans.length = group.wayOccurrences;

        WayDecodeSummary waySummary;
        if (!decodeWaysWithWorkspace(
                block,
                group,
                table,
                workspace.wayPlans[0 .. group.wayOccurrences],
                sink,
                waySummary,
                status))
        {
            readStatus = fromPbfFailure(
                PbfReadStage.way,
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        RelationDecodeSummary relationSummary;
        if (!decodeRelations(
                block,
                group,
                table,
                sink,
                relationSummary,
                status))
        {
            readStatus = fromPbfFailure(
                PbfReadStage.relation,
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        summary.nodes += denseSummary.nodeCount;
        summary.nodes += nodeSummary.nodeCount;
        summary.ways += waySummary.wayCount;
        summary.relations += relationSummary.relationCount;
        summary.tags += denseSummary.tagCount;
        summary.tags += nodeSummary.tagCount;
        summary.tags += waySummary.tagCount;
        summary.tags += relationSummary.tagCount;
        ++summary.primitiveGroups;
    }

    ++summary.dataBlocks;
    readStatus = PbfReadStatus.init;
    return true;
}

private struct SemanticSink(Handler)
{
private:
    Handler* handler;

public:
    this(ref Handler value) @trusted nothrow @nogc
    {
        handler = &value;
    }

    void putDenseNodeScalars(long id, long latNano, long lonNano)
        @trusted nothrow @nogc
    {
        static if (__traits(hasMember, Handler, "node"))
        {
            DenseNodeView node;
            node.id = id;
            node.latNano = latNano;
            node.lonNano = lonNano;
            callNode(*handler, node);
        }
    }

    void put(scope ref DenseNodeView node) @trusted nothrow @nogc
    {
        static if (__traits(hasMember, Handler, "node"))
            callNode(*handler, node);
    }

    void put(scope ref NodeView node) @trusted nothrow @nogc
    {
        static if (__traits(hasMember, Handler, "node"))
            callNode(*handler, node);
    }

    void put(scope ref WayView way) @trusted nothrow @nogc
    {
        static if (__traits(hasMember, Handler, "way"))
            callWay(*handler, way);
    }

    void put(scope ref RelationView relation) @trusted nothrow @nogc
    {
        static if (__traits(hasMember, Handler, "relation"))
            callRelation(*handler, relation);
    }
}

private void callNode(Handler, View)(
    ref Handler handler,
    scope ref View node)
    @safe nothrow @nogc
{
    handler.node(node);
}

private void callWay(Handler)(
    ref Handler handler,
    scope ref WayView way)
    @safe nothrow @nogc
{
    handler.way(way);
}

private void callRelation(Handler)(
    ref Handler handler,
    scope ref RelationView relation)
    @safe nothrow @nogc
{
    handler.relation(relation);
}

private PbfReadStatus readerFailure(
    PbfReadError error,
    PbfReadStage stage,
    ulong sequence,
    size_t blockOffset)
    @safe pure nothrow @nogc
{
    PbfReadStatus result;
    result.error = error;
    result.stage = stage;
    result.blockSequence = sequence;
    result.blockOffset = blockOffset;
    return result;
}

private PbfReadStatus fromPbfFailure(
    PbfReadStage stage,
    ulong sequence,
    size_t blockOffset,
    PbfStatus detail)
    @safe pure nothrow @nogc
{
    PbfReadStatus result;
    result.error = classifyPbfError(detail.error);
    result.stage = stage;
    result.blockSequence = sequence;
    result.blockOffset = blockOffset;
    result.detail = detail.error;
    result.detailOffset = detail.offset;
    result.detailFieldNumber = detail.fieldNumber;
    return result;
}

private PbfReadError classifyPbfError(PbfError error)
    @safe pure nothrow @nogc
{
    switch (error)
    {
        case PbfError.none:
            return PbfReadError.none;
        case PbfError.unsupportedRequiredFeature:
            return PbfReadError.unsupportedFeature;
        case PbfError.unsupportedBlobCompression:
        case PbfError.obsoleteBlobCompression:
            return PbfReadError.unsupportedCompression;
        default:
            return PbfReadError.malformedInput;
    }
}

version(unittest)
{
    private void appendVarint(ref ubyte[] target, ulong value)
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

    private void appendVarintField(
        ref ubyte[] target,
        uint fieldNumber,
        ulong value)
    {
        appendVarint(target, cast(ulong)(fieldNumber << 3));
        appendVarint(target, value);
    }

    private void appendLengthDelimited(
        ref ubyte[] target,
        uint fieldNumber,
        const(ubyte)[] value)
    {
        appendVarint(target, cast(ulong)((fieldNumber << 3) | 2));
        appendVarint(target, value.length);
        target ~= value;
    }

    private void appendAsciiLengthDelimited(
        ref ubyte[] target,
        uint fieldNumber,
        string value)
    {
        appendVarint(target, cast(ulong)((fieldNumber << 3) | 2));
        appendVarint(target, value.length);
        foreach (char c; value)
            target ~= cast(ubyte)c;
    }

    private void appendFileBlock(
        ref ubyte[] target,
        string blockType,
        const(ubyte)[] payload)
    {
        ubyte[] blob;
        appendLengthDelimited(blob, 1, payload);

        ubyte[] header;
        appendAsciiLengthDelimited(header, 1, blockType);
        appendVarintField(header, 3, blob.length);

        const length = cast(uint)header.length;
        target ~= cast(ubyte)(length >> 24);
        target ~= cast(ubyte)(length >> 16);
        target ~= cast(ubyte)(length >> 8);
        target ~= cast(ubyte)length;
        target ~= header;
        target ~= blob;
    }

    private ubyte[] makePrimitiveBlock(const(ubyte)[] group = null)
    {
        ubyte[] table;
        appendLengthDelimited(table, 1, null);

        ubyte[] block;
        appendLengthDelimited(block, 1, table);
        if (group.length != 0)
            appendLengthDelimited(block, 2, group);
        return block;
    }
}

unittest
{
    ubyte[] node;
    appendVarintField(node, 1, 2); // sint64 id = 1
    appendVarintField(node, 8, 0); // sint64 lat = 0
    appendVarintField(node, 9, 0); // sint64 lon = 0

    ubyte[] group;
    appendLengthDelimited(group, 1, node);

    ubyte[] input;
    appendFileBlock(input, "OSMHeader", null);
    const data = makePrimitiveBlock(group);
    appendFileBlock(input, "OSMData", data);

    struct Handler
    {
        size_t nodes;
        long lastId;

        void node(T)(scope ref T value) @safe nothrow @nogc
        {
            ++nodes;
            lastId = value.id;
        }
    }

    PbfReader reader;
    PbfReaderWorkspace workspace;
    Handler handler;
    PbfReadSummary summary;
    PbfReadStatus status;

    assert(reader.read(input, workspace, handler, summary, status));
    assert(status.ok);
    assert(summary.headerBlocks == 1);
    assert(summary.dataBlocks == 1);
    assert(summary.primitiveGroups == 1);
    assert(summary.nodes == 1);
    assert(summary.ways == 0);
    assert(summary.relations == 0);
    assert(summary.tags == 0);
    assert(handler.nodes == 1);
    assert(handler.lastId == 1);
}

unittest
{
    struct Handler {}

    PbfReader reader;
    PbfReaderWorkspace workspace;
    Handler handler;
    PbfReadSummary summary;
    PbfReadStatus status;

    assert(!reader.read(null, workspace, handler, summary, status));
    assert(status.error == PbfReadError.missingHeader);

    ubyte[] dataOnly;
    const data = makePrimitiveBlock();
    appendFileBlock(dataOnly, "OSMData", data);
    assert(!reader.read(dataOnly, workspace, handler, summary, status));
    assert(status.error == PbfReadError.dataBeforeHeader);

    ubyte[] duplicateHeader;
    appendFileBlock(duplicateHeader, "OSMHeader", null);
    appendFileBlock(duplicateHeader, "OSMHeader", null);
    assert(!reader.read(
        duplicateHeader,
        workspace,
        handler,
        summary,
        status));
    assert(status.error == PbfReadError.duplicateHeader);

    ubyte[] unknownBlock;
    appendFileBlock(unknownBlock, "OSMHeader", null);
    appendFileBlock(unknownBlock, "FutureBlock", null);
    assert(!reader.read(unknownBlock, workspace, handler, summary, status));
    assert(status.error == PbfReadError.unsupportedBlockType);

    ubyte[] changeSetGroup;
    appendLengthDelimited(changeSetGroup, 5, null);
    const changeSetBlock = makePrimitiveBlock(changeSetGroup);

    ubyte[] changeSetFile;
    appendFileBlock(changeSetFile, "OSMHeader", null);
    appendFileBlock(changeSetFile, "OSMData", changeSetBlock);
    assert(!reader.read(changeSetFile, workspace, handler, summary, status));
    assert(status.error == PbfReadError.unsupportedChangeSet);
}
