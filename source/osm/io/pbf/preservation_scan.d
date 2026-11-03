/**
 * Loss-aware scan of protobuf/PBF source structure before semantic rewrite.
 *
 * The ordinary semantic decoders intentionally skip unknown protobuf fields.
 * M4 additionally needs to know that such source content existed so a semantic
 * rewrite cannot silently erase it. This module walks the complete PBF message
 * tree with the current schema's field/wire contracts and records the first
 * source class that is not represented by the owned semantic document.
 *
 * The scan does not replace normal decoding or validation. Malformed input is
 * still reported through the existing PBF reader status machinery.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.preservation_scan;

import osm.io.pbf.blob : BlobView, decodeBlob;
import osm.io.pbf.blob_header : BlobKind;
import osm.io.pbf.decompress : BlobPayloadView;
import osm.io.pbf.error : PbfStatus;
import osm.io.pbf.features : HeaderFeatureKind, classifyHeaderFeature;
import osm.io.pbf.framing :
    FileBlockView, FrameReadResult, readFileBlock;
import osm.io.pbf.header_block : HeaderBlockView, decodeHeaderBlock;
import osm.io.pbf.reader :
    PbfReadError,
    PbfReadStatus,
    PbfReaderWorkspace,
    decodeReaderBlobPayload,
    fromPbfFailure,
    readerFailure;
import osm.raw.pbf :
    PbfPreservation,
    PbfPreservationReason;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;

/** Internal protobuf message schemas relevant to semantic PBF rewrite. */
private enum MessageKind : ubyte
{
    blobHeader,
    blob,
    headerBlock,
    headerBBox,
    primitiveBlock,
    stringTable,
    primitiveGroup,
    node,
    denseNodes,
    info,
    denseInfo,
    way,
    relation,
}

private struct FieldRule
{
    bool known;
    bool nested;
    MessageKind child;
    bool unsupportedSemantic;
}

/**
 * Scan one complete PBF file for source content not represented by M4.
 *
 * `preservation.source` is owned by the caller/document and is not modified.
 * The first preservation reason wins in file-block order.
 */
package(osm)
bool scanPbfPreservation(
    const(ubyte)[] input,
    ref PbfReaderWorkspace workspace,
    ref PbfPreservation preservation,
    out PbfReadStatus status)
    @safe
{
    status = PbfReadStatus.init;

    auto cursor = WireCursor(input);
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
                return true;

            case FrameReadResult.error:
                status = fromPbfFailure(sequence, blockOffset, pbfStatus);
                return false;

            case FrameReadResult.block:
                if (!scanMessage(
                        fileBlock.header.raw,
                        MessageKind.blobHeader,
                        fileBlock.offset,
                        preservation,
                        pbfStatus))
                {
                    status = fromPbfFailure(
                        sequence,
                        fileBlock.offset,
                        pbfStatus);
                    return false;
                }

                if (!scanMessage(
                        fileBlock.blob,
                        MessageKind.blob,
                        fileBlock.offset,
                        preservation,
                        pbfStatus))
                {
                    status = fromPbfFailure(
                        sequence,
                        fileBlock.offset,
                        pbfStatus);
                    return false;
                }

                BlobView blob;
                if (!decodeBlob(fileBlock.blob, blob, pbfStatus))
                {
                    status = fromPbfFailure(
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
                    status = fromPbfFailure(
                        sequence,
                        fileBlock.offset,
                        pbfStatus);
                    return false;
                }

                final switch (fileBlock.header.kind)
                {
                    case BlobKind.osmHeader:
                        if (!scanMessage(
                                payload.bytes,
                                MessageKind.headerBlock,
                                fileBlock.offset,
                                preservation,
                                pbfStatus))
                        {
                            status = fromPbfFailure(
                                sequence,
                                fileBlock.offset,
                                pbfStatus);
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

                        auto required = header.requiredFeatures;
                        while (!required.empty)
                        {
                            if (classifyHeaderFeature(required.front.bytes) ==
                                HeaderFeatureKind.unknown)
                            {
                                notePreservation(
                                    preservation,
                                    PbfPreservationReason
                                        .unsupportedSemanticContent,
                                    fileBlock.offset);
                            }
                            required.popFront();
                        }

                        auto optional = header.optionalFeatures;
                        while (!optional.empty)
                        {
                            if (classifyHeaderFeature(optional.front.bytes) ==
                                HeaderFeatureKind.unknown)
                            {
                                notePreservation(
                                    preservation,
                                    PbfPreservationReason
                                        .unknownOptionalFeature,
                                    fileBlock.offset);
                            }
                            optional.popFront();
                        }
                        break;

                    case BlobKind.osmData:
                        if (!scanMessage(
                                payload.bytes,
                                MessageKind.primitiveBlock,
                                fileBlock.offset,
                                preservation,
                                pbfStatus))
                        {
                            status = fromPbfFailure(
                                sequence,
                                fileBlock.offset,
                                pbfStatus);
                            return false;
                        }
                        break;

                    case BlobKind.unknown:
                        notePreservation(
                            preservation,
                            PbfPreservationReason
                                .unsupportedSemanticContent,
                            fileBlock.offset);
                        status = readerFailure(
                            PbfReadError.unsupportedBlockType,
                            sequence,
                            fileBlock.offset);
                        return false;
                }

                ++sequence;
                break;
        }
    }
}

private bool scanMessage(
    const(ubyte)[] bytes,
    MessageKind kind,
    size_t fileBlockOffset,
    ref PbfPreservation preservation,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto cursor = WireCursor(bytes);

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromWire(wire);
            return false;
        }

        const rule = fieldRule(kind, field.number, field.wireType);
        if (!rule.known)
        {
            notePreservation(
                preservation,
                PbfPreservationReason.unknownField,
                fileBlockOffset);

            if (!skipFieldValue(cursor, field, wire))
            {
                status = PbfStatus.fromWire(wire);
                return false;
            }
            continue;
        }

        if (rule.unsupportedSemantic)
        {
            notePreservation(
                preservation,
                PbfPreservationReason.unsupportedSemanticContent,
                fileBlockOffset);
        }

        if (rule.nested)
        {
            const(ubyte)[] payload;
            if (!readLengthDelimited(
                    cursor,
                    field.number,
                    payload,
                    wire))
            {
                status = PbfStatus.fromWire(wire);
                return false;
            }

            if (!scanMessage(
                    payload,
                    rule.child,
                    fileBlockOffset,
                    preservation,
                    status))
            {
                return false;
            }
            continue;
        }

        if (!skipFieldValue(cursor, field, wire))
        {
            status = PbfStatus.fromWire(wire);
            return false;
        }
    }

    status = PbfStatus.init;
    return true;
}

private FieldRule fieldRule(
    MessageKind kind,
    uint number,
    WireType wireType)
    @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case MessageKind.blobHeader:
            switch (number)
            {
                case 1:
                case 2:
                    return scalarRule(wireType == WireType.lengthDelimited);
                case 3:
                    return scalarRule(wireType == WireType.varint);
                default:
                    return FieldRule.init;
            }

        case MessageKind.blob:
            switch (number)
            {
                case 1:
                case 3:
                case 4:
                case 5:
                case 6:
                case 7:
                    return scalarRule(wireType == WireType.lengthDelimited);
                case 2:
                    return scalarRule(wireType == WireType.varint);
                default:
                    return FieldRule.init;
            }

        case MessageKind.headerBlock:
            switch (number)
            {
                case 1:
                    return nestedRule(
                        wireType == WireType.lengthDelimited,
                        MessageKind.headerBBox);
                case 4:
                case 5:
                case 16:
                case 17:
                case 34:
                    return scalarRule(wireType == WireType.lengthDelimited);
                case 32:
                case 33:
                    return scalarRule(wireType == WireType.varint);
                default:
                    return FieldRule.init;
            }

        case MessageKind.headerBBox:
            if (number >= 1 && number <= 4)
                return scalarRule(wireType == WireType.varint);
            return FieldRule.init;

        case MessageKind.primitiveBlock:
            switch (number)
            {
                case 1:
                    return nestedRule(
                        wireType == WireType.lengthDelimited,
                        MessageKind.stringTable);
                case 2:
                    return nestedRule(
                        wireType == WireType.lengthDelimited,
                        MessageKind.primitiveGroup);
                case 17:
                case 18:
                case 19:
                case 20:
                    return scalarRule(wireType == WireType.varint);
                default:
                    return FieldRule.init;
            }

        case MessageKind.stringTable:
            return number == 1
                ? scalarRule(wireType == WireType.lengthDelimited)
                : FieldRule.init;

        case MessageKind.primitiveGroup:
            switch (number)
            {
                case 1:
                    return nestedRule(
                        wireType == WireType.lengthDelimited,
                        MessageKind.node);
                case 2:
                    return nestedRule(
                        wireType == WireType.lengthDelimited,
                        MessageKind.denseNodes);
                case 3:
                    return nestedRule(
                        wireType == WireType.lengthDelimited,
                        MessageKind.way);
                case 4:
                    return nestedRule(
                        wireType == WireType.lengthDelimited,
                        MessageKind.relation);
                case 5:
                    if (wireType != WireType.lengthDelimited)
                        return FieldRule.init;
                    FieldRule unsupported;
                    unsupported.known = true;
                    unsupported.unsupportedSemantic = true;
                    return unsupported;
                default:
                    return FieldRule.init;
            }

        case MessageKind.node:
            switch (number)
            {
                case 1:
                case 8:
                case 9:
                    return scalarRule(wireType == WireType.varint);
                case 2:
                case 3:
                    return scalarRule(isPackableWire(wireType));
                case 4:
                    return nestedRule(
                        wireType == WireType.lengthDelimited,
                        MessageKind.info);
                default:
                    return FieldRule.init;
            }

        case MessageKind.denseNodes:
            switch (number)
            {
                case 1:
                case 8:
                case 9:
                case 10:
                    return scalarRule(isPackableWire(wireType));
                case 5:
                    return nestedRule(
                        wireType == WireType.lengthDelimited,
                        MessageKind.denseInfo);
                default:
                    return FieldRule.init;
            }

        case MessageKind.info:
            if (number >= 1 && number <= 6)
                return scalarRule(wireType == WireType.varint);
            return FieldRule.init;

        case MessageKind.denseInfo:
            if (number >= 1 && number <= 6)
                return scalarRule(isPackableWire(wireType));
            return FieldRule.init;

        case MessageKind.way:
            switch (number)
            {
                case 1:
                    return scalarRule(wireType == WireType.varint);
                case 2:
                case 3:
                case 8:
                case 9:
                case 10:
                    return scalarRule(isPackableWire(wireType));
                case 4:
                    return nestedRule(
                        wireType == WireType.lengthDelimited,
                        MessageKind.info);
                default:
                    return FieldRule.init;
            }

        case MessageKind.relation:
            switch (number)
            {
                case 1:
                    return scalarRule(wireType == WireType.varint);
                case 2:
                case 3:
                case 8:
                case 9:
                case 10:
                    return scalarRule(isPackableWire(wireType));
                case 4:
                    return nestedRule(
                        wireType == WireType.lengthDelimited,
                        MessageKind.info);
                default:
                    return FieldRule.init;
            }
    }
}

private FieldRule scalarRule(bool matches)
    @safe pure nothrow @nogc
{
    FieldRule result;
    result.known = matches;
    return result;
}

private FieldRule nestedRule(bool matches, MessageKind child)
    @safe pure nothrow @nogc
{
    FieldRule result;
    result.known = matches;
    result.nested = matches;
    result.child = child;
    return result;
}

private bool isPackableWire(WireType wireType)
    @safe pure nothrow @nogc
{
    return wireType == WireType.varint ||
           wireType == WireType.lengthDelimited;
}

private void notePreservation(
    ref PbfPreservation preservation,
    PbfPreservationReason reason,
    size_t fileBlockOffset)
    @safe pure nothrow @nogc
{
    if (preservation.reason != PbfPreservationReason.none)
        return;

    preservation.reason = reason;
    preservation.firstSensitiveOffset = fileBlockOffset;
}

unittest
{
    PbfPreservation preservation;
    PbfStatus status;

    // Node(id=1, unknown fixed32 field 15, lat=0, lon=0).
    const(ubyte)[] node = [
        0x08, 0x02,
        0x7d, 0xde, 0xad, 0xbe, 0xef,
        0x40, 0x00,
        0x48, 0x00,
    ];

    assert(scanMessage(
        node,
        MessageKind.node,
        123,
        preservation,
        status));
    assert(status.ok);
    assert(preservation.reason == PbfPreservationReason.unknownField);
    assert(preservation.firstSensitiveOffset == 123);
}

unittest
{
    PbfPreservation preservation;
    PbfStatus status;

    // Wrong-wire known Node id is an unknown protobuf occurrence and therefore
    // must block semantic rewrite even if a later correct id exists.
    const(ubyte)[] node = [
        0x0a, 0x00,
        0x08, 0x02,
        0x40, 0x00,
        0x48, 0x00,
    ];

    assert(scanMessage(
        node,
        MessageKind.node,
        9,
        preservation,
        status));
    assert(preservation.reason == PbfPreservationReason.unknownField);
}
