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
import osm.io.pbf.blob_header : BlobHeaderView, BlobKind, decodeBlobHeader;
import osm.io.pbf.decompress :
    BlobPayloadView,
    decodeBlobPayloadInto,
    requiredOutputSize;
import osm.io.pbf.dense_nodes :
    DenseNodeDecodeSummary,
    DenseNodeView,
    decodeDenseNodes,
    decodeDenseNodesUntilStop;
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
import osm.io.pbf.limits : maxBlobHeaderSize;
import pbfNode = osm.io.pbf.node;
import osm.io.pbf.node_view : NodeView;
import osm.io.pbf.primitive_block :
    PrimitiveBlockLayout,
    decodePrimitiveBlockLayout;
import osm.io.pbf.primitive_group :
    PrimitiveGroupLayout,
    decodePrimitiveGroupLayout;
import osm.io.pbf.relation :
    RelationDecodeSummary,
    RelationView,
    decodeRelations,
    decodeRelationsUntilStop;
import osm.io.pbf.string_table :
    StringRef,
    StringTableView,
    buildStringTableView;
import osm.io.pbf.way :
    WayDecodePlan,
    WayDecodeSummary,
    WayView,
    decodeWaysWithWorkspace,
    decodeWaysWithWorkspaceUntilStop;
import osm.util.endian : readBigEndianU32;
import osm.wire.cursor : WireCursor;
import transport.source : ByteSource, ReadError, ReadLimits;

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

/**
 * Diagnostic for one complete-file PBF read.
 *
 * `error` is the stable high-level category. `blockSequence` and
 * `blockOffset` identify the enclosing file block when one was being
 * processed. Detailed protobuf/PBF decoder diagnostics deliberately remain
 * below this consumer boundary and are available from the direct low-level
 * PBF APIs.
 *
 * `PbfReadStatus.init` is the successful status.
 */
struct PbfReadStatus
{
    /// High-level failure category; `PbfReadError.none` denotes success.
    PbfReadError error = PbfReadError.none;
    /// Zero-based file-block sequence being processed.
    ulong blockSequence;
    /// Offset of the enclosing file block in the complete input buffer.
    size_t blockOffset;

    /** Returns true when no read error has occurred. */
    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == PbfReadError.none;
    }
}

/**
 * Combined transport/PBF diagnostic for one ByteSource-backed PBF read.
 *
 * A clean source EOF is not a transport failure. When EOF occurs in the middle
 * of a PBF frame, `transportError` remains `ReadError.none` and `pbf`
 * reports malformed/truncated input, preserving the distinction between an
 * incomplete encoded file and an actual byte-source failure.
 */
struct PbfSourceReadStatus
{
    /// PBF semantic/framing status. Successful when transport alone failed.
    PbfReadStatus pbf;
    /// Generic transport failure, or ReadError.none.
    ReadError transportError = ReadError.none;
    /// Absolute source offset of the failed transport request.
    ulong transportOffset;
    /// Bytes returned by the failed transport request, when any.
    size_t transportBytesRead;

    /** True only when both transport and PBF processing succeeded. */
    @property bool ok() const @safe pure nothrow @nogc
    {
        return transportError == ReadError.none && pbf.ok;
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

    // ByteSource framing scratch. Lengths retain the largest observed frame
    // pieces so subsequent source reads reuse capacity without whole-file
    // materialization.
    ubyte[] sourceHeaderBuffer;
    ubyte[] sourceBlobBuffer;
}

/**
 * Materialize one validated Blob payload using reusable reader scratch.
 *
 * This package-internal boundary lets block-level reader implementations share
 * the existing decompression-buffer ownership without exposing workspace
 * representation to consumers.
 */
package(osm)
bool decodeReaderBlobPayload(
    const BlobView blob,
    ref PbfReaderWorkspace workspace,
    out BlobPayloadView payload,
    out PbfStatus status)
    @safe
{
    const outputSize = requiredOutputSize(blob);
    if (workspace.decompressionBuffer.length < outputSize)
        workspace.decompressionBuffer.length = outputSize;

    return decodeBlobPayloadInto(
        blob,
        workspace.decompressionBuffer,
        payload,
        status);
}


private enum SourceFrameReadResult : ubyte
{
    block,
    endOfInput,
    pbfError,
    transportError,
}

private void growSourceBuffer(ref ubyte[] buffer, size_t required) @safe
{
    if (buffer.length < required)
        buffer.length = required;
}

private SourceFrameReadResult readSourceFileBlock(
    scope ByteSource source,
    ref ulong sourceOffset,
    ulong sequence,
    ref PbfReaderWorkspace workspace,
    out FileBlockView block,
    out PbfStatus pbfStatus,
    out ReadError transportError,
    out ulong transportOffset,
    out size_t transportBytesRead)
    @safe
{
    block = FileBlockView.init;
    pbfStatus = PbfStatus.init;
    transportError = ReadError.none;
    transportOffset = 0;
    transportBytesRead = 0;

    const ulong blockOffset64 = sourceOffset;
    const size_t blockOffset = cast(size_t)blockOffset64;

    ubyte[4] prefix = void;
    auto prefixRead = source.readSome(
        sourceOffset,
        prefix[],
        ReadLimits(prefix.length));

    if (prefixRead.error == ReadError.endOfSource)
    {
        if (prefixRead.bytesRead == 0)
            return SourceFrameReadResult.endOfInput;

        pbfStatus = PbfStatus.failure(
            PbfError.truncatedHeaderLength,
            blockOffset);
        return SourceFrameReadResult.pbfError;
    }

    if (!prefixRead.ok)
    {
        transportError = prefixRead.error;
        transportOffset = sourceOffset;
        transportBytesRead = prefixRead.bytesRead;
        return SourceFrameReadResult.transportError;
    }

    if (prefixRead.bytesRead != prefix.length)
    {
        pbfStatus = PbfStatus.failure(
            PbfError.truncatedHeaderLength,
            blockOffset);
        return SourceFrameReadResult.pbfError;
    }

    uint headerLength;
    if (!readBigEndianU32(prefix[], 0, headerLength))
    {
        pbfStatus = PbfStatus.failure(
            PbfError.truncatedHeaderLength,
            blockOffset);
        return SourceFrameReadResult.pbfError;
    }

    if (headerLength >= maxBlobHeaderSize)
    {
        pbfStatus = PbfStatus.failure(
            PbfError.blobHeaderTooLarge,
            blockOffset);
        return SourceFrameReadResult.pbfError;
    }

    const ulong headerOffset64 = sourceOffset + prefix.length;
    const size_t headerOffset = cast(size_t)headerOffset64;
    const size_t headerSize = cast(size_t)headerLength;
    growSourceBuffer(workspace.sourceHeaderBuffer, headerSize);
    auto headerBytes = workspace.sourceHeaderBuffer[0 .. headerSize];

    if (headerSize != 0)
    {
        auto headerRead = source.readSome(
            headerOffset64,
            headerBytes,
            ReadLimits(headerSize));

        if (headerRead.error == ReadError.endOfSource ||
            (headerRead.ok && headerRead.bytesRead != headerSize))
        {
            pbfStatus = PbfStatus.failure(
                PbfError.truncatedBlobHeader,
                headerOffset);
            return SourceFrameReadResult.pbfError;
        }

        if (!headerRead.ok)
        {
            transportError = headerRead.error;
            transportOffset = headerOffset64;
            transportBytesRead = headerRead.bytesRead;
            return SourceFrameReadResult.transportError;
        }
    }

    BlobHeaderView header;
    if (!decodeBlobHeader(headerBytes, header, pbfStatus))
    {
        pbfStatus.offset += headerOffset;
        return SourceFrameReadResult.pbfError;
    }

    const ulong blobOffset64 = headerOffset64 + headerSize;
    const size_t blobOffset = cast(size_t)blobOffset64;
    const size_t blobSize = cast(size_t)header.dataSize;
    growSourceBuffer(workspace.sourceBlobBuffer, blobSize);
    auto blobBytes = workspace.sourceBlobBuffer[0 .. blobSize];

    if (blobSize != 0)
    {
        auto blobRead = source.readSome(
            blobOffset64,
            blobBytes,
            ReadLimits(blobSize));

        if (blobRead.error == ReadError.endOfSource ||
            (blobRead.ok && blobRead.bytesRead != blobSize))
        {
            pbfStatus = PbfStatus.failure(
                PbfError.truncatedBlobData,
                blobOffset);
            return SourceFrameReadResult.pbfError;
        }

        if (!blobRead.ok)
        {
            transportError = blobRead.error;
            transportOffset = blobOffset64;
            transportBytesRead = blobRead.bytesRead;
            return SourceFrameReadResult.transportError;
        }
    }

    block = FileBlockView(
        sequence,
        blockOffset,
        header,
        blobBytes);

    sourceOffset = blobOffset64 + blobSize;
    return SourceFrameReadResult.block;
}

/**
 * Foreach adapter over semantic OSM nodes in one already-loaded PBF file.
 *
 * This is deliberately a foreach/opApply adapter rather than a Phobos
 * InputRange. The underlying PBF decoders are synchronous push decoders; using
 * opApply preserves that execution model and lets D propagate `break`,
 * enclosing `return`, and outer `goto` through the delegate's exact control
 * value without materializing elements or introducing a coroutine runtime.
 *
 * A natural traversal to end-of-file retains the same whole-file validation
 * scope as PbfReader.read: Ways and Relations are decoded/validated but are not
 * delivered to the node foreach body. If iteration stops early, parsing stops
 * immediately after the node that produced the foreach control value, so the
 * unvisited file suffix is deliberately not validated.
 *
 * Scratch storage is local to each opApply invocation. It may grow through the
 * garbage collector in the same cases as a fresh PbfReaderWorkspace, but there
 * is no per-node allocation or owned node materialization.
 *
 * After foreach finishes, inspect `status`. A successful natural traversal
 * has `status.ok == true` and `completed == true`. A user `break` has
 * `status.ok == true` and `completed == false`. A decode failure has
 * `status.ok == false` and `completed == false`.
 *
 * `PbfNodeIterable.init` represents an empty input. Iterating it produces no
 * nodes and records `PbfReadError.missingHeader`.
 */
struct PbfNodeIterable
{
private:
    const(ubyte)[] input;
    PbfReadStatus _status;
    bool _completed;

package(osm):
    this(return scope const(ubyte)[] value)
        @safe pure nothrow @nogc
    {
        input = value;
    }

public:
    /** Status from the most recent foreach traversal. */
    @property PbfReadStatus status() const
        @safe pure nothrow @nogc
    {
        return _status;
    }

    /** True only when the most recent traversal reached the end of the file. */
    @property bool completed() const
        @safe pure nothrow @nogc
    {
        return _completed;
    }

    /**
     * Iterate semantic nodes from an @safe foreach body.
     *
     * The delegate return value is forwarded unchanged. D uses that non-zero
     * value to implement foreach `break`, enclosing `return`, and outer
     * `goto`; returning any invented non-zero value would violate opApply
     * semantics.
     */
    int opApply(
        scope int delegate(scope ref NodeView) @safe dg)
        @safe
    {
        SafeNodeForeachSink sink = SafeNodeForeachSink(dg);
        return apply(sink);
    }

    /** Iterate semantic nodes from an @system foreach body. */
    int opApply(
        scope int delegate(scope ref NodeView) @system dg)
        @system
    {
        SystemNodeForeachSink sink = SystemNodeForeachSink(dg);
        return apply(sink);
    }

private:
    int apply(Sink)(ref Sink sink)
    {
        _status = PbfReadStatus.init;
        _completed = false;

        PbfReaderWorkspace workspace;
        int control;

        if (!iterateNodes(
                input,
                workspace,
                sink,
                control,
                _status))
        {
            return 0;
        }

        if (control != 0)
            return control;

        _completed = true;
        return 0;
    }
}

/**
 * Foreach adapter over semantic OSM Ways in one already-loaded PBF file.
 *
 * Natural traversal retains whole-file validation. An early foreach exit stops
 * parsing immediately after the Way that produced the control value and leaves
 * the unvisited suffix deliberately unvalidated.
 */
struct PbfWayIterable
{
private:
    const(ubyte)[] input;
    PbfReadStatus _status;
    bool _completed;

package(osm):
    this(return scope const(ubyte)[] value)
        @safe pure nothrow @nogc
    {
        input = value;
    }

public:
    /** Status from the most recent foreach traversal. */
    @property PbfReadStatus status() const
        @safe pure nothrow @nogc
    {
        return _status;
    }

    /** True only when the most recent traversal reached the end of the file. */
    @property bool completed() const
        @safe pure nothrow @nogc
    {
        return _completed;
    }

    /** Iterate semantic Ways from an @safe foreach body. */
    int opApply(
        scope int delegate(scope ref WayView) @safe dg)
        @safe
    {
        SafeWayForeachSink sink = SafeWayForeachSink(dg);
        return apply(sink);
    }

    /** Iterate semantic Ways from an @system foreach body. */
    int opApply(
        scope int delegate(scope ref WayView) @system dg)
        @system
    {
        SystemWayForeachSink sink = SystemWayForeachSink(dg);
        return apply(sink);
    }

private:
    int apply(Sink)(ref Sink sink)
    {
        _status = PbfReadStatus.init;
        _completed = false;

        PbfReaderWorkspace workspace;
        int control;

        if (!iterateSelected!decodeWayDataBlock(
                input,
                workspace,
                sink,
                control,
                _status))
        {
            return 0;
        }

        if (control != 0)
            return control;

        _completed = true;
        return 0;
    }
}

/**
 * Foreach adapter over semantic OSM Relations in one already-loaded PBF file.
 *
 * Natural traversal retains whole-file validation. An early foreach exit stops
 * parsing immediately after the Relation that produced the control value and
 * leaves the unvisited suffix deliberately unvalidated.
 */
struct PbfRelationIterable
{
private:
    const(ubyte)[] input;
    PbfReadStatus _status;
    bool _completed;

package(osm):
    this(return scope const(ubyte)[] value)
        @safe pure nothrow @nogc
    {
        input = value;
    }

public:
    /** Status from the most recent foreach traversal. */
    @property PbfReadStatus status() const
        @safe pure nothrow @nogc
    {
        return _status;
    }

    /** True only when the most recent traversal reached the end of the file. */
    @property bool completed() const
        @safe pure nothrow @nogc
    {
        return _completed;
    }

    /** Iterate semantic Relations from an @safe foreach body. */
    int opApply(
        scope int delegate(scope ref RelationView) @safe dg)
        @safe
    {
        SafeRelationForeachSink sink = SafeRelationForeachSink(dg);
        return apply(sink);
    }

    /** Iterate semantic Relations from an @system foreach body. */
    int opApply(
        scope int delegate(scope ref RelationView) @system dg)
        @system
    {
        SystemRelationForeachSink sink = SystemRelationForeachSink(dg);
        return apply(sink);
    }

private:
    int apply(Sink)(ref Sink sink)
    {
        _status = PbfReadStatus.init;
        _completed = false;

        PbfReaderWorkspace workspace;
        int control;

        if (!iterateSelected!decodeRelationDataBlock(
                input,
                workspace,
                sink,
                control,
                _status))
        {
            return 0;
        }

        if (control != 0)
            return control;

        _completed = true;
        return 0;
    }
}

/**
 * Push-filter adapter over one element-specific PBF foreach traversal.
 *
 * This is deliberately not a Phobos InputRange. It retains the synchronous
 * opApply execution model of pbfNodes/pbfWays/pbfRelations, applies a
 * compile-time predicate to each valid borrowed element, and forwards only
 * matching elements to the final foreach body.
 *
 * The adapter owns only a copy of the source traversal value. It does not
 * materialize OSM elements, widen borrowed lifetimes, or skip the parsing and
 * validation work required to produce a valid element view.
 *
 * Consumers normally obtain this type through UFCS:
 *
 * ---
 * auto highways = pbfWays(input).where!hasHighway;
 * foreach (scope ref WayView way; highways)
 * {
 *     // matching borrowed Way only
 * }
 * ---
 *
 * A natural traversal preserves the source whole-file validation scope.
 * Breaking from the final foreach body stops parsing immediately and leaves
 * completed false, exactly like the unfiltered source traversal.
 */
struct PbfWhereIterable(Source, View, alias predicate)
{
private:
    Source source;

    this(return scope Source value)
        @safe pure nothrow @nogc
    {
        source = value;
    }

public:
    /** Status from the most recent traversal. */
    @property PbfReadStatus status() const
        @safe pure nothrow @nogc
    {
        return source.status;
    }

    /** True only when the most recent traversal reached end-of-file. */
    @property bool completed() const
        @safe pure nothrow @nogc
    {
        return source.completed;
    }

    /** Iterate matching elements from an @safe foreach body. */
    int opApply(
        scope int delegate(scope ref View) @safe dg)
        @safe
    {
        return source.opApply((scope ref View value) @safe {
            if (!predicate(value))
                return 0;
            return dg(value);
        });
    }

    /** Iterate matching elements from an @system foreach body. */
    int opApply(
        scope int delegate(scope ref View) @system dg)
        @system
    {
        return source.opApply((scope ref View value) @system {
            if (!predicate(value))
                return 0;
            return dg(value);
        });
    }
}

/**
 * Filter one PBF Node foreach traversal with a compile-time predicate.
 *
 * The predicate receives the same callback-scoped NodeView as ordinary
 * pbfNodes traversal. For non-copyable NodeView predicates, accept the value by
 * scope ref.
 */
PbfWhereIterable!(PbfNodeIterable, NodeView, predicate)
where(alias predicate)(return scope PbfNodeIterable source)
    @safe pure nothrow @nogc
{
    return typeof(return)(source);
}

/** Filter one PBF Way foreach traversal with a compile-time predicate. */
PbfWhereIterable!(PbfWayIterable, WayView, predicate)
where(alias predicate)(return scope PbfWayIterable source)
    @safe pure nothrow @nogc
{
    return typeof(return)(source);
}

/** Filter one PBF Relation foreach traversal with a compile-time predicate. */
PbfWhereIterable!(PbfRelationIterable, RelationView, predicate)
where(alias predicate)(return scope PbfRelationIterable source)
    @safe pure nothrow @nogc
{
    return typeof(return)(source);
}

/**
 * Whole-buffer OSMPBF reader.
 *
 * The reader is stateless; reusable allocation belongs to PbfReaderWorkspace.
 * PbfReader.init is therefore a valid reader.
 *
 * Handler callbacks are discovered statically by name. A handler may omit
 * node, way, or relation entirely when that element kind is not needed. When a
 * node callback is present it accepts one concrete semantic NodeView for both
 * regular Node and DenseNodes encoding. Callbacks execute
 * synchronously and must satisfy @safe nothrow @nogc. Borrowed views must not
 * escape the callback.
 */
struct PbfReader
{
    /**
     * Return a foreach adapter over semantic nodes in `input`.
     *
     * The returned adapter owns no input bytes and materializes no OSM
     * elements. See PbfNodeIterable for completion and validation semantics.
     */
    PbfNodeIterable nodes(return scope const(ubyte)[] input)
        @safe pure nothrow @nogc
    {
        return PbfNodeIterable(input);
    }

    /** Return a foreach adapter over semantic Ways in `input`. */
    PbfWayIterable ways(return scope const(ubyte)[] input)
        @safe pure nothrow @nogc
    {
        return PbfWayIterable(input);
    }

    /** Return a foreach adapter over semantic Relations in `input`. */
    PbfRelationIterable relations(return scope const(ubyte)[] input)
        @safe pure nothrow @nogc
    {
        return PbfRelationIterable(input);
    }

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
                        sequence,
                        blockOffset,
                        pbfStatus);
                    return false;

                case FrameReadResult.block:
                    BlobView blob;
                    if (!decodeBlob(fileBlock.blob, blob, pbfStatus))
                    {
                        status = fromPbfFailure(
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
                sequence,
                input.length);
            return false;
        }


        return true;
    }

    /**
     * Decode one complete PBF from a bounded generic ByteSource.
     *
     * The source is consumed monotonically through `readSome`. Only the
     * current BlobHeader, serialized Blob and existing reusable decode
     * workspace are retained; the complete encoded resource is never
     * materialized by this overload.
     *
     * A clean EOF at a block boundary completes the file. EOF inside a frame is
     * a malformed/truncated PBF error, while generic source failures remain
     * explicit in `PbfSourceReadStatus.transportError`.
     */
    bool read(Handler)(
        scope ByteSource source,
        ref PbfReaderWorkspace workspace,
        ref Handler handler,
        out PbfReadSummary summary,
        out PbfSourceReadStatus sourceStatus)
        @safe
    {
        summary = PbfReadSummary.init;
        sourceStatus = PbfSourceReadStatus.init;

        if (source is null)
        {
            sourceStatus.transportError = ReadError.sourceFailure;
            return false;
        }

        SemanticSink!Handler sink = SemanticSink!Handler(handler);
        bool sawHeader;
        bool sawData;
        ulong sequence;
        ulong sourceOffset;

        while (true)
        {
            const size_t blockOffset = cast(size_t)sourceOffset;
            FileBlockView fileBlock;
            PbfStatus pbfStatus;
            ReadError transportError;
            ulong transportOffset;
            size_t transportBytesRead;

            const frameResult = readSourceFileBlock(
                source,
                sourceOffset,
                sequence,
                workspace,
                fileBlock,
                pbfStatus,
                transportError,
                transportOffset,
                transportBytesRead);

            final switch (frameResult)
            {
                case SourceFrameReadResult.endOfInput:
                    break;

                case SourceFrameReadResult.transportError:
                    sourceStatus.transportError = transportError;
                    sourceStatus.transportOffset = transportOffset;
                    sourceStatus.transportBytesRead = transportBytesRead;
                    return false;

                case SourceFrameReadResult.pbfError:
                    sourceStatus.pbf = fromPbfFailure(
                        sequence,
                        blockOffset,
                        pbfStatus);
                    return false;

                case SourceFrameReadResult.block:
                    BlobView blob;
                    if (!decodeBlob(fileBlock.blob, blob, pbfStatus))
                    {
                        sourceStatus.pbf = fromPbfFailure(
                            sequence,
                            fileBlock.offset,
                            pbfStatus);
                        return false;
                    }

                    BlobPayloadView payload;
                    if (!decodeReaderBlobPayload(
                            blob,
                            workspace,
                            payload,
                            pbfStatus))
                    {
                        sourceStatus.pbf = fromPbfFailure(
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
                                sourceStatus.pbf = readerFailure(
                                    PbfReadError.duplicateHeader,
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
                                sourceStatus.pbf = fromPbfFailure(
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
                                sourceStatus.pbf = fromPbfFailure(
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
                                sourceStatus.pbf = readerFailure(
                                    PbfReadError.dataBeforeHeader,
                                    sequence,
                                    fileBlock.offset);
                                return false;
                            }

                            sawData = true;
                            PbfReadStatus blockStatus;
                            if (!decodeDataBlock(
                                    payload.bytes,
                                    workspace,
                                    sink,
                                    summary,
                                    sequence,
                                    fileBlock.offset,
                                    blockStatus))
                            {
                                sourceStatus.pbf = blockStatus;
                                return false;
                            }
                            break;

                        case BlobKind.unknown:
                            sourceStatus.pbf = readerFailure(
                                PbfReadError.unsupportedBlockType,
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
            sourceStatus.pbf = readerFailure(
                PbfReadError.missingHeader,
                sequence,
                cast(size_t)sourceOffset);
            return false;
        }

        return true;
    }
}


/**
 * Result of the one-shot `readPbf` convenience operation.
 *
 * `ok` is equivalent to `status.ok`. Summary counters are complete only
 * when `ok` is true.
 */
struct PbfReadResult
{
    PbfReadSummary summary;
    PbfReadStatus status;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return status.ok;
    }
}

/** One-shot result for a ByteSource-backed PBF read. */
struct PbfSourceReadResult
{
    PbfReadSummary summary;
    PbfSourceReadStatus status;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return status.ok;
    }
}

/**
 * Decode one complete PBF with a temporary reader workspace.
 *
 * This is the ordinary one-shot entry point. Repeated/high-throughput callers
 * should keep a `PbfReaderWorkspace` and call `PbfReader.read` directly so
 * scratch capacity is reused across files.
 */
PbfReadResult readPbf(Handler)(
    const(ubyte)[] input,
    ref Handler handler) @safe
{
    PbfReader reader;
    PbfReaderWorkspace workspace;
    PbfReadResult result;
    reader.read(
        input,
        workspace,
        handler,
        result.summary,
        result.status);
    return result;
}

/**
 * Decode one complete PBF from a generic ByteSource with temporary scratch.
 *
 * Repeated/high-throughput callers should retain a PbfReaderWorkspace and call
 * PbfReader.read directly so block/decompression/index scratch is reused.
 */
PbfSourceReadResult readPbf(Handler)(
    scope ByteSource source,
    ref Handler handler) @safe
{
    PbfReader reader;
    PbfReaderWorkspace workspace;
    PbfSourceReadResult result;
    reader.read(
        source,
        workspace,
        handler,
        result.summary,
        result.status);
    return result;
}

/** Return a foreach adapter over semantic Nodes in one PBF input. */
PbfNodeIterable pbfNodes(return scope const(ubyte)[] input)
    @safe pure nothrow @nogc
{
    return PbfNodeIterable(input);
}

/** Return a foreach adapter over semantic Ways in one PBF input. */
PbfWayIterable pbfWays(return scope const(ubyte)[] input)
    @safe pure nothrow @nogc
{
    return PbfWayIterable(input);
}

/** Return a foreach adapter over semantic Relations in one PBF input. */
PbfRelationIterable pbfRelations(return scope const(ubyte)[] input)
    @safe pure nothrow @nogc
{
    return PbfRelationIterable(input);
}

private bool iterateNodes(Sink)(
    const(ubyte)[] input,
    ref PbfReaderWorkspace workspace,
    ref Sink sink,
    out int control,
    out PbfReadStatus status)
{
    control = 0;
    status = PbfReadStatus.init;

    auto cursor = WireCursor(input);
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
                    sequence,
                    blockOffset,
                    pbfStatus);
                return false;

            case FrameReadResult.block:
                BlobView blob;
                if (!decodeBlob(fileBlock.blob, blob, pbfStatus))
                {
                    status = fromPbfFailure(
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
                                sequence,
                                fileBlock.offset,
                                pbfStatus);
                            return false;
                        }

                        sawHeader = true;
                        break;

                    case BlobKind.osmData:
                        if (!sawHeader)
                        {
                            status = readerFailure(
                                PbfReadError.dataBeforeHeader,
                                sequence,
                                fileBlock.offset);
                            return false;
                        }

                        sawData = true;
                        if (!decodeNodeDataBlock(
                                payload.bytes,
                                workspace,
                                sink,
                                control,
                                sequence,
                                fileBlock.offset,
                                status))
                        {
                            return false;
                        }

                        if (control != 0)
                            return true;
                        break;

                    case BlobKind.unknown:
                        status = readerFailure(
                            PbfReadError.unsupportedBlockType,
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
            sequence,
            input.length);
        return false;
    }

    status = PbfReadStatus.init;
    return true;
}

private bool decodeNodeDataBlock(Sink)(
    const(ubyte)[] payloadBytes,
    ref PbfReaderWorkspace workspace,
    ref Sink sink,
    ref int control,
    ulong sequence,
    size_t fileBlockOffset,
    out PbfReadStatus readStatus)
{
    PbfStatus status;

    PrimitiveBlockLayout block;
    if (!decodePrimitiveBlockLayout(payloadBytes, block, status))
    {
        readStatus = fromPbfFailure(
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
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (group.changeSetOccurrences != 0)
        {
            readStatus = readerFailure(
                PbfReadError.unsupportedChangeSet,
                sequence,
                fileBlockOffset);
            return false;
        }

        DenseNodeDecodeSummary denseSummary;
        if (!decodeDenseNodesUntilStop(
                block,
                group,
                table,
                sink,
                control,
                denseSummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (control != 0)
        {
            readStatus = PbfReadStatus.init;
            return true;
        }

        pbfNode.NodeDecodeSummary nodeSummary;
        if (!pbfNode.decodeNodesUntilStop(
                block,
                group,
                table,
                sink,
                control,
                nodeSummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (control != 0)
        {
            readStatus = PbfReadStatus.init;
            return true;
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
                sequence,
                fileBlockOffset,
                status);
            return false;
        }
    }

    readStatus = PbfReadStatus.init;
    return true;
}

private struct SafeNodeForeachSink
{
private:
    int delegate(scope ref NodeView) @safe dg;

public:
    this(scope int delegate(scope ref NodeView) @safe value)
        @trusted nothrow @nogc
    {
        // value is scope to opApply and this sink never leaves that call.
        dg = value;
    }

    int putDenseNodeScalars(long id, long latNano, long lonNano)
        @safe
    {
        NodeView node = NodeView(id, latNano, lonNano);
        return dg(node);
    }

    int put(scope ref DenseNodeView encoded)
        @safe
    {
        NodeView node = NodeView(encoded);
        return dg(node);
    }

    int put(scope ref pbfNode.NodeView encoded)
        @safe
    {
        NodeView node = NodeView(encoded);
        return dg(node);
    }

    void put(scope ref WayView) @safe nothrow @nogc {}
    void put(scope ref RelationView) @safe nothrow @nogc {}
}

private struct SystemNodeForeachSink
{
private:
    int delegate(scope ref NodeView) @system dg;

public:
    this(scope int delegate(scope ref NodeView) @system value)
        @system nothrow @nogc
    {
        dg = value;
    }

    int putDenseNodeScalars(long id, long latNano, long lonNano)
        @system
    {
        NodeView node = NodeView(id, latNano, lonNano);
        return dg(node);
    }

    int put(scope ref DenseNodeView encoded)
        @system
    {
        NodeView node = NodeView(encoded);
        return dg(node);
    }

    int put(scope ref pbfNode.NodeView encoded)
        @system
    {
        NodeView node = NodeView(encoded);
        return dg(node);
    }

    void put(scope ref WayView) @safe nothrow @nogc {}
    void put(scope ref RelationView) @safe nothrow @nogc {}
}

private bool iterateSelected(alias decodeSelectedDataBlock, Sink)(
    const(ubyte)[] input,
    ref PbfReaderWorkspace workspace,
    ref Sink sink,
    out int control,
    out PbfReadStatus status)
{
    control = 0;
    status = PbfReadStatus.init;

    auto cursor = WireCursor(input);
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
                    sequence,
                    blockOffset,
                    pbfStatus);
                return false;

            case FrameReadResult.block:
                BlobView blob;
                if (!decodeBlob(fileBlock.blob, blob, pbfStatus))
                {
                    status = fromPbfFailure(
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
                                sequence,
                                fileBlock.offset,
                                pbfStatus);
                            return false;
                        }

                        sawHeader = true;
                        break;

                    case BlobKind.osmData:
                        if (!sawHeader)
                        {
                            status = readerFailure(
                                PbfReadError.dataBeforeHeader,
                                sequence,
                                fileBlock.offset);
                            return false;
                        }

                        sawData = true;
                        if (!decodeSelectedDataBlock(
                                payload.bytes,
                                workspace,
                                sink,
                                control,
                                sequence,
                                fileBlock.offset,
                                status))
                        {
                            return false;
                        }

                        if (control != 0)
                            return true;
                        break;

                    case BlobKind.unknown:
                        status = readerFailure(
                            PbfReadError.unsupportedBlockType,
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
            sequence,
            input.length);
        return false;
    }

    status = PbfReadStatus.init;
    return true;
}

private bool decodeWayDataBlock(Sink)(
    const(ubyte)[] payloadBytes,
    ref PbfReaderWorkspace workspace,
    ref Sink sink,
    ref int control,
    ulong sequence,
    size_t fileBlockOffset,
    out PbfReadStatus readStatus)
{
    PbfStatus status;

    PrimitiveBlockLayout block;
    if (!decodePrimitiveBlockLayout(payloadBytes, block, status))
    {
        readStatus = fromPbfFailure(
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
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (group.changeSetOccurrences != 0)
        {
            readStatus = readerFailure(
                PbfReadError.unsupportedChangeSet,
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
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        pbfNode.NodeDecodeSummary nodeSummary;
        if (!pbfNode.decodeNodes(
                block,
                group,
                table,
                sink,
                nodeSummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (workspace.wayPlans.length < group.wayOccurrences)
            workspace.wayPlans.length = group.wayOccurrences;

        WayDecodeSummary waySummary;
        if (!decodeWaysWithWorkspaceUntilStop(
                block,
                group,
                table,
                workspace.wayPlans[0 .. group.wayOccurrences],
                sink,
                control,
                waySummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (control != 0)
        {
            readStatus = PbfReadStatus.init;
            return true;
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
                sequence,
                fileBlockOffset,
                status);
            return false;
        }
    }

    readStatus = PbfReadStatus.init;
    return true;
}

private bool decodeRelationDataBlock(Sink)(
    const(ubyte)[] payloadBytes,
    ref PbfReaderWorkspace workspace,
    ref Sink sink,
    ref int control,
    ulong sequence,
    size_t fileBlockOffset,
    out PbfReadStatus readStatus)
{
    PbfStatus status;

    PrimitiveBlockLayout block;
    if (!decodePrimitiveBlockLayout(payloadBytes, block, status))
    {
        readStatus = fromPbfFailure(
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
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (group.changeSetOccurrences != 0)
        {
            readStatus = readerFailure(
                PbfReadError.unsupportedChangeSet,
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
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        pbfNode.NodeDecodeSummary nodeSummary;
        if (!pbfNode.decodeNodes(
                block,
                group,
                table,
                sink,
                nodeSummary,
                status))
        {
            readStatus = fromPbfFailure(
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
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        RelationDecodeSummary relationSummary;
        if (!decodeRelationsUntilStop(
                block,
                group,
                table,
                sink,
                control,
                relationSummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (control != 0)
        {
            readStatus = PbfReadStatus.init;
            return true;
        }
    }

    readStatus = PbfReadStatus.init;
    return true;
}

private struct SafeWayForeachSink
{
private:
    int delegate(scope ref WayView) @safe dg;

public:
    this(scope int delegate(scope ref WayView) @safe value)
        @trusted nothrow @nogc
    {
        dg = value;
    }

    void putDenseNodeScalars(long, long, long) @safe nothrow @nogc {}
    void put(scope ref DenseNodeView) @safe nothrow @nogc {}
    void put(scope ref pbfNode.NodeView) @safe nothrow @nogc {}

    int put(scope ref WayView way) @safe
    {
        return dg(way);
    }

    void put(scope ref RelationView) @safe nothrow @nogc {}
}

private struct SystemWayForeachSink
{
private:
    int delegate(scope ref WayView) @system dg;

public:
    this(scope int delegate(scope ref WayView) @system value)
        @system nothrow @nogc
    {
        dg = value;
    }

    void putDenseNodeScalars(long, long, long) @safe nothrow @nogc {}
    void put(scope ref DenseNodeView) @safe nothrow @nogc {}
    void put(scope ref pbfNode.NodeView) @safe nothrow @nogc {}

    int put(scope ref WayView way) @system
    {
        return dg(way);
    }

    void put(scope ref RelationView) @safe nothrow @nogc {}
}

private struct SafeRelationForeachSink
{
private:
    int delegate(scope ref RelationView) @safe dg;

public:
    this(scope int delegate(scope ref RelationView) @safe value)
        @trusted nothrow @nogc
    {
        dg = value;
    }

    void putDenseNodeScalars(long, long, long) @safe nothrow @nogc {}
    void put(scope ref DenseNodeView) @safe nothrow @nogc {}
    void put(scope ref pbfNode.NodeView) @safe nothrow @nogc {}
    void put(scope ref WayView) @safe nothrow @nogc {}

    int put(scope ref RelationView relation) @safe
    {
        return dg(relation);
    }
}

private struct SystemRelationForeachSink
{
private:
    int delegate(scope ref RelationView) @system dg;

public:
    this(scope int delegate(scope ref RelationView) @system value)
        @system nothrow @nogc
    {
        dg = value;
    }

    void putDenseNodeScalars(long, long, long) @safe nothrow @nogc {}
    void put(scope ref DenseNodeView) @safe nothrow @nogc {}
    void put(scope ref pbfNode.NodeView) @safe nothrow @nogc {}
    void put(scope ref WayView) @safe nothrow @nogc {}

    int put(scope ref RelationView relation) @system
    {
        return dg(relation);
    }
}

package(osm)
bool decodeDataBlock(Sink)(
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
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (group.changeSetOccurrences != 0)
        {
            readStatus = readerFailure(
                PbfReadError.unsupportedChangeSet,
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
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        pbfNode.NodeDecodeSummary nodeSummary;
        if (!pbfNode.decodeNodes(
                block,
                group,
                table,
                sink,
                nodeSummary,
                status))
        {
            readStatus = fromPbfFailure(
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
            NodeView node = NodeView(id, latNano, lonNano);
            callNode(*handler, node);
        }
    }

    void put(scope ref DenseNodeView encoded) @trusted nothrow @nogc
    {
        static if (__traits(hasMember, Handler, "node"))
        {
            NodeView node = NodeView(encoded);
            callNode(*handler, node);
        }
    }

    void put(scope ref pbfNode.NodeView encoded) @trusted nothrow @nogc
    {
        static if (__traits(hasMember, Handler, "node"))
        {
            NodeView node = NodeView(encoded);
            callNode(*handler, node);
        }
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

private void callNode(Handler)(
    ref Handler handler,
    scope ref NodeView node)
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

package(osm)
PbfReadStatus readerFailure(
    PbfReadError error,
    ulong sequence,
    size_t blockOffset)
    @safe pure nothrow @nogc
{
    PbfReadStatus result;
    result.error = error;
    result.blockSequence = sequence;
    result.blockOffset = blockOffset;
    return result;
}

package(osm)
PbfReadStatus fromPbfFailure(
    ulong sequence,
    size_t blockOffset,
    PbfStatus detail)
    @safe pure nothrow @nogc
{
    PbfReadStatus result;
    result.error = classifyPbfError(detail.error);
    result.blockSequence = sequence;
    result.blockOffset = blockOffset;
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

version(unittest)
{
    private bool testEvenNode(scope ref NodeView value)
        @safe pure nothrow @nogc
    {
        return (value.id & 1) == 0;
    }

    private bool testEvenWay(scope ref WayView value)
        @safe pure nothrow @nogc
    {
        return (value.id & 1) == 0;
    }

    private bool testEvenRelation(scope ref RelationView value)
        @safe pure nothrow @nogc
    {
        return (value.id & 1) == 0;
    }

    private bool testNoWay(scope ref WayView)
        @safe pure nothrow @nogc
    {
        return false;
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

        void node(scope ref NodeView value) @safe nothrow @nogc
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


// PbfNodeIterable foreach natural completion and early-stop semantics.
unittest
{
    ubyte[] first;
    appendVarintField(first, 1, 2); // sint64 id = 1
    appendVarintField(first, 8, 0);
    appendVarintField(first, 9, 0);

    ubyte[] second;
    appendVarintField(second, 1, 4); // sint64 id = 2
    appendVarintField(second, 8, 0);
    appendVarintField(second, 9, 0);

    ubyte[] group;
    appendLengthDelimited(group, 1, first);
    appendLengthDelimited(group, 1, second);

    ubyte[] input;
    appendFileBlock(input, "OSMHeader", null);
    const data = makePrimitiveBlock(group);
    appendFileBlock(input, "OSMData", data);

    PbfReader reader;

    auto all = reader.nodes(input);
    size_t count;
    long idSum;
    foreach (scope ref NodeView node; all)
    {
        ++count;
        idSum += node.id;
    }

    assert(all.status.ok);
    assert(all.completed);
    assert(count == 2);
    assert(idSum == 3);

    auto prefix = reader.nodes(input);
    count = 0;
    foreach (scope ref NodeView node; prefix)
    {
        ++count;
        assert(node.id == 1);
        break;
    }

    assert(prefix.status.ok);
    assert(!prefix.completed);
    assert(count == 1);
}


// PbfNodeIterable exercises the DenseNodes scalar fast representation too.
unittest
{
    const(ubyte)[] ids = [0x02, 0x02]; // delta ids 1, 1
    const(ubyte)[] coords = [0x00, 0x00];

    ubyte[] dense;
    appendLengthDelimited(dense, 1, ids);
    appendLengthDelimited(dense, 8, coords);
    appendLengthDelimited(dense, 9, coords);

    ubyte[] group;
    appendLengthDelimited(group, 2, dense);

    ubyte[] input;
    appendFileBlock(input, "OSMHeader", null);
    const data = makePrimitiveBlock(group);
    appendFileBlock(input, "OSMData", data);

    PbfReader reader;
    auto nodes = reader.nodes(input);

    size_t count;
    long idSum;
    foreach (scope ref NodeView node; nodes)
    {
        ++count;
        idSum += node.id;
    }

    assert(nodes.status.ok);
    assert(nodes.completed);
    assert(count == 2);
    assert(idSum == 3);
}


// Decode errors terminate foreach naturally and remain available as status.
unittest
{
    PbfReader reader;
    auto nodes = reader.nodes(null);

    size_t count;
    foreach (scope ref NodeView node; nodes)
    {
        ++count;
    }

    assert(count == 0);
    assert(!nodes.completed);
    assert(nodes.status.error == PbfReadError.missingHeader);
}


// PbfNodeIterable break leaves the unvisited file suffix unchecked.
unittest
{
    ubyte[] node;
    appendVarintField(node, 1, 2); // sint64 id = 1
    appendVarintField(node, 8, 0);
    appendVarintField(node, 9, 0);

    ubyte[] group;
    appendLengthDelimited(group, 1, node);

    ubyte[] input;
    appendFileBlock(input, "OSMHeader", null);

    const firstData = makePrimitiveBlock(group);
    appendFileBlock(input, "OSMData", firstData);

    // A second framed OSMData block whose PrimitiveBlock payload contains a
    // truncated protobuf key. Natural traversal must reach and reject it;
    // breaking after the first node must stop before this block is inspected.
    const(ubyte)[] malformedSecondData = [0x80];
    appendFileBlock(input, "OSMData", malformedSecondData);

    PbfReader reader;

    auto complete = reader.nodes(input);
    size_t completeCount;
    foreach (scope ref NodeView value; complete)
    {
        ++completeCount;
        assert(value.id == 1);
    }

    assert(completeCount == 1);
    assert(!complete.completed);
    assert(complete.status.error == PbfReadError.malformedInput);

    auto prefix = reader.nodes(input);
    size_t prefixCount;
    foreach (scope ref NodeView value; prefix)
    {
        ++prefixCount;
        assert(value.id == 1);
        break;
    }

    assert(prefixCount == 1);
    assert(prefix.status.ok);
    assert(!prefix.completed);
}


// PbfWayIterable natural completion and early stop.
unittest
{
    ubyte[] way;
    appendVarintField(way, 1, 7);

    ubyte[] group;
    appendLengthDelimited(group, 3, way);

    ubyte[] input;
    appendFileBlock(input, "OSMHeader", null);
    const data = makePrimitiveBlock(group);
    appendFileBlock(input, "OSMData", data);

    PbfReader reader;
    auto ways = reader.ways(input);

    size_t count;
    long idSum;
    foreach (scope ref WayView value; ways)
    {
        ++count;
        idSum += value.id;
    }

    assert(ways.status.ok);
    assert(ways.completed);
    assert(count == 1);
    assert(idSum == 7);

    ubyte[] malformedGroup;
    appendLengthDelimited(malformedGroup, 4, null); // malformed Relation

    ubyte[] suffixInput;
    appendFileBlock(suffixInput, "OSMHeader", null);
    appendFileBlock(suffixInput, "OSMData", data);
    const malformedData = makePrimitiveBlock(malformedGroup);
    appendFileBlock(suffixInput, "OSMData", malformedData);

    auto complete = reader.ways(suffixInput);
    count = 0;
    foreach (scope ref WayView value; complete)
    {
        ++count;
        assert(value.id == 7);
    }

    assert(count == 1);
    assert(!complete.completed);
    assert(complete.status.error == PbfReadError.malformedInput);

    auto prefix = reader.ways(suffixInput);
    count = 0;
    foreach (scope ref WayView value; prefix)
    {
        ++count;
        assert(value.id == 7);
        break;
    }

    assert(count == 1);
    assert(prefix.status.ok);
    assert(!prefix.completed);
}


// PbfRelationIterable natural completion and early stop.
unittest
{
    ubyte[] relation;
    appendVarintField(relation, 1, 9);

    ubyte[] group;
    appendLengthDelimited(group, 4, relation);

    ubyte[] input;
    appendFileBlock(input, "OSMHeader", null);
    const data = makePrimitiveBlock(group);
    appendFileBlock(input, "OSMData", data);

    PbfReader reader;
    auto relations = reader.relations(input);

    size_t count;
    long idSum;
    foreach (scope ref RelationView value; relations)
    {
        ++count;
        idSum += value.id;
    }

    assert(relations.status.ok);
    assert(relations.completed);
    assert(count == 1);
    assert(idSum == 9);

    ubyte[] malformedGroup;
    appendLengthDelimited(malformedGroup, 4, null);

    ubyte[] suffixInput;
    appendFileBlock(suffixInput, "OSMHeader", null);
    appendFileBlock(suffixInput, "OSMData", data);
    const malformedData = makePrimitiveBlock(malformedGroup);
    appendFileBlock(suffixInput, "OSMData", malformedData);

    auto complete = reader.relations(suffixInput);
    count = 0;
    foreach (scope ref RelationView value; complete)
    {
        ++count;
        assert(value.id == 9);
    }

    assert(count == 1);
    assert(!complete.completed);
    assert(complete.status.error == PbfReadError.malformedInput);

    auto prefix = reader.relations(suffixInput);
    count = 0;
    foreach (scope ref RelationView value; prefix)
    {
        ++count;
        assert(value.id == 9);
        break;
    }

    assert(count == 1);
    assert(prefix.status.ok);
    assert(!prefix.completed);
}


// Push filtering preserves borrowed traversal, validation and early-stop status.
unittest
{
    // Nodes: use the same minimal regular-Node shape as the established
    // PbfNodeIterable tests.
    ubyte[] node1;
    appendVarintField(node1, 1, 2); // sint64 id = 1
    appendVarintField(node1, 8, 0);
    appendVarintField(node1, 9, 0);

    ubyte[] node2;
    appendVarintField(node2, 1, 4); // sint64 id = 2
    appendVarintField(node2, 8, 0);
    appendVarintField(node2, 9, 0);

    ubyte[] nodeGroup;
    appendLengthDelimited(nodeGroup, 1, node1);
    appendLengthDelimited(nodeGroup, 1, node2);

    ubyte[] nodeInput;
    appendFileBlock(nodeInput, "OSMHeader", null);
    const nodeData = makePrimitiveBlock(nodeGroup);
    appendFileBlock(nodeInput, "OSMData", nodeData);

    auto nodes = pbfNodes(nodeInput).where!testEvenNode;
    size_t nodeCount;
    foreach (scope ref NodeView value; nodes)
    {
        ++nodeCount;
        assert(value.id == 2);
    }
    assert(nodeCount == 1);
    assert(nodes.status.ok);
    assert(nodes.completed);

    // Ways.
    ubyte[] way7;
    appendVarintField(way7, 1, 7);
    ubyte[] way8;
    appendVarintField(way8, 1, 8);

    ubyte[] wayGroup;
    appendLengthDelimited(wayGroup, 3, way7);
    appendLengthDelimited(wayGroup, 3, way8);

    ubyte[] wayInput;
    appendFileBlock(wayInput, "OSMHeader", null);
    const wayData = makePrimitiveBlock(wayGroup);
    appendFileBlock(wayInput, "OSMData", wayData);

    auto ways = pbfWays(wayInput).where!testEvenWay;
    size_t wayCount;
    foreach (scope ref WayView value; ways)
    {
        ++wayCount;
        assert(value.id == 8);
    }
    assert(wayCount == 1);
    assert(ways.status.ok);
    assert(ways.completed);

    // Relations.
    ubyte[] relation9;
    appendVarintField(relation9, 1, 9);
    ubyte[] relation10;
    appendVarintField(relation10, 1, 10);

    ubyte[] relationGroup;
    appendLengthDelimited(relationGroup, 4, relation9);
    appendLengthDelimited(relationGroup, 4, relation10);

    ubyte[] relationInput;
    appendFileBlock(relationInput, "OSMHeader", null);
    const relationData = makePrimitiveBlock(relationGroup);
    appendFileBlock(relationInput, "OSMData", relationData);

    auto relations = pbfRelations(relationInput).where!testEvenRelation;
    size_t relationCount;
    foreach (scope ref RelationView value; relations)
    {
        ++relationCount;
        assert(value.id == 10);
    }
    assert(relationCount == 1);
    assert(relations.status.ok);
    assert(relations.completed);

    // The final foreach control value still stops the source traversal.
    auto prefix = pbfWays(wayInput).where!testEvenWay;
    foreach (scope ref WayView value; prefix)
    {
        assert(value.id == 8);
        break;
    }
    assert(prefix.status.ok);
    assert(!prefix.completed);

    // Filtering every valid Way out does not suppress validation of the
    // following malformed PBF block.
    ubyte[] malformed;
    appendFileBlock(malformed, "OSMHeader", null);
    appendFileBlock(malformed, "OSMData", wayData);
    const(ubyte)[] badPrimitiveBlock = [0x80];
    appendFileBlock(malformed, "OSMData", badPrimitiveBlock);

    auto none = pbfWays(malformed).where!testNoWay;
    wayCount = 0;
    foreach (scope ref WayView value; none)
        ++wayCount;

    assert(wayCount == 0);
    assert(!none.completed);
    assert(none.status.error == PbfReadError.malformedInput);
}

