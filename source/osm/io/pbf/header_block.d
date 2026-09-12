/**
 * Zero-copy decoder for the OSMPBF `HeaderBlock` protobuf message.
 *
 * The decoder follows the canonical `osmformat.proto` schema while keeping the
 * complete serialized message available as `HeaderBlockView.raw`. Singular
 * scalar and string fields use protobuf's last-one-wins behavior. Repeated
 * feature strings remain in wire order and are exposed through allocation-free
 * input ranges. Repeated occurrences of the singular embedded `HeaderBBox`
 * field are merged, matching protobuf message-field semantics.
 *
 * Header strings are exposed as raw bytes at this layer. No implicit UTF-8
 * repair or normalization is performed. `HeaderBBox` coordinates are retained
 * exactly as signed integer nanodegrees and are never converted through
 * floating point.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.header_block;

import osm.io.pbf.error : PbfError, PbfStatus;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    readLengthDelimited,
    skipFieldValue;
import osm.wire.varint : readSVarint64, readVarint64;

/**
 * Exact bounding box carried by an OSMPBF HeaderBlock.
 *
 * All coordinates are signed nanodegrees, exactly as encoded by `HeaderBBox`.
 */
struct HeaderBBoxView
{
    /// Western longitude in nanodegrees.
    long left;
    /// Eastern longitude in nanodegrees.
    long right;
    /// Northern latitude in nanodegrees.
    long top;
    /// Southern latitude in nanodegrees.
    long bottom;
}

/** One repeated HeaderBlock feature occurrence and its wire offset. */
struct HeaderFeatureRef
{
    /// Raw bytes of the protobuf `string` value.
    const(ubyte)[] bytes;
    /// Offset of the field key within the serialized HeaderBlock.
    size_t offset;
}

/**
 * Allocation-free input range over one repeated feature field.
 *
 * Instances are produced by `HeaderBlockView.requiredFeatures` and
 * `HeaderBlockView.optionalFeatures`. The underlying HeaderBlock has already
 * been structurally validated, so rescanning cannot introduce a new semantic
 * interpretation or allocate memory.
 */
struct HeaderFeatureRange
{
private:
    WireCursor _cursor;
    uint _fieldNumber;
    HeaderFeatureRef _front;
    bool _hasFront;

    this(const(ubyte)[] raw, uint fieldNumber) @safe nothrow @nogc
    {
        _cursor = WireCursor(raw);
        _fieldNumber = fieldNumber;
        advance();
    }

    void advance() @safe nothrow @nogc
    {
        _hasFront = false;
        _front = HeaderFeatureRef.init;

        while (!_cursor.empty)
        {
            FieldHeader field;
            WireStatus wire;
            if (!readFieldHeader(_cursor, field, wire))
            {
                _cursor = WireCursor(null);
                return;
            }

            if (field.number == _fieldNumber &&
                field.wireType == WireType.lengthDelimited)
            {
                const(ubyte)[] value;
                if (!readLengthDelimited(
                    _cursor,
                    field.number,
                    value,
                    wire))
                {
                    _cursor = WireCursor(null);
                    return;
                }

                _front = HeaderFeatureRef(value, field.offset);
                _hasFront = true;
                return;
            }

            if (!skipFieldValue(_cursor, field, wire))
            {
                _cursor = WireCursor(null);
                return;
            }
        }
    }

public:
    /** Returns `true` after all matching feature occurrences are consumed. */
    @property bool empty() const @safe pure nothrow @nogc
    {
        return !_hasFront;
    }

    /** Returns the current feature occurrence. Valid only while non-empty. */
    @property HeaderFeatureRef front() const @safe pure nothrow @nogc
    {
        return _front;
    }

    /** Advance to the next feature occurrence. */
    void popFront() @safe nothrow @nogc
    {
        if (_hasFront)
            advance();
    }
}

/**
 * Borrowed semantic view of a structurally valid OSMPBF HeaderBlock.
 *
 * Every byte slice borrows `raw`. Presence flags distinguish an absent optional
 * field from a present field carrying its protobuf default/empty value.
 */
struct HeaderBlockView
{
    /// Complete serialized HeaderBlock, including unknown fields and duplicates.
    const(ubyte)[] raw;
    /// Merged HeaderBBox value when `hasBBox` is true.
    HeaderBBoxView bbox;
    /// Last correctly encoded `writingprogram` value.
    const(ubyte)[] writingProgram;
    /// Last correctly encoded `source` value.
    const(ubyte)[] source;
    /// Last replication timestamp value in seconds since the Unix epoch.
    long replicationTimestamp;
    /// Last Osmosis replication sequence number.
    long replicationSequenceNumber;
    /// Last replication base URL value.
    const(ubyte)[] replicationBaseUrl;
    /// Whether at least one correctly encoded `bbox` occurrence was present.
    bool hasBBox;
    /// Whether `writingprogram` was present.
    bool hasWritingProgram;
    /// Whether `source` was present.
    bool hasSource;
    /// Whether `osmosis_replication_timestamp` was present.
    bool hasReplicationTimestamp;
    /// Whether `osmosis_replication_sequence_number` was present.
    bool hasReplicationSequenceNumber;
    /// Whether `osmosis_replication_base_url` was present.
    bool hasReplicationBaseUrl;

    /** Returns the required feature occurrences in original wire order. */
    @property HeaderFeatureRange requiredFeatures() const @safe nothrow @nogc
    {
        return HeaderFeatureRange(raw, 4);
    }

    /** Returns the optional feature occurrences in original wire order. */
    @property HeaderFeatureRange optionalFeatures() const @safe nothrow @nogc
    {
        return HeaderFeatureRange(raw, 5);
    }
}

private struct HeaderBBoxAccumulator
{
    HeaderBBoxView value;
    bool left;
    bool right;
    bool top;
    bool bottom;
}

/**
 * Decode one complete serialized OSMPBF `HeaderBlock`.
 *
 * Unknown non-group protobuf fields are skipped semantically but remain in
 * `HeaderBlockView.raw`. Known fields carrying the wrong wire type are treated
 * as unknown occurrences, consistent with protobuf forward-compatible parsing.
 * A present HeaderBBox must contain all four required coordinates after all
 * repeated message occurrences have been merged.
 *
 * Params:
 *   input = Complete uncompressed HeaderBlock payload bytes.
 *   header = Receives the zero-copy decoded view on success.
 *   status = Receives success or a precise structural/wire failure.
 *
 * Returns:
 *   `true` when the HeaderBlock is structurally valid; `false` otherwise.
 *
 * Notes:
 *   Required-feature compatibility is deliberately evaluated separately by
 *   `osm.io.pbf.features`. Structural decoding alone does not claim that the
 *   caller understands every feature required by the file.
 */
bool decodeHeaderBlock(
    const(ubyte)[] input,
    out HeaderBlockView header,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto cursor = WireCursor(input);
    HeaderBlockView decoded;
    decoded.raw = input;
    HeaderBBoxAccumulator bbox;

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            header = HeaderBlockView.init;
            status = PbfStatus.fromHeaderBlockWire(wire);
            return false;
        }

        switch (field.number)
        {
            case 1:
                if (field.wireType == WireType.lengthDelimited)
                {
                    const(ubyte)[] payload;
                    if (!readLengthDelimited(
                        cursor,
                        field.number,
                        payload,
                        wire))
                    {
                        header = HeaderBlockView.init;
                        status = PbfStatus.fromHeaderBlockWire(wire);
                        return false;
                    }

                    const payloadOffset = cursor.offset - payload.length;
                    if (!mergeHeaderBBox(payload, payloadOffset, bbox, status))
                    {
                        header = HeaderBlockView.init;
                        return false;
                    }
                    decoded.hasBBox = true;
                }
                else if (!skipUnknownValue(cursor, field, status))
                {
                    header = HeaderBlockView.init;
                    return false;
                }
                break;

            case 4:
            case 5:
                // Repeated feature strings are intentionally left in `raw` and
                // exposed lazily through HeaderFeatureRange.
                if (field.wireType == WireType.lengthDelimited)
                {
                    const(ubyte)[] ignored;
                    if (!readLengthDelimited(
                        cursor,
                        field.number,
                        ignored,
                        wire))
                    {
                        header = HeaderBlockView.init;
                        status = PbfStatus.fromHeaderBlockWire(wire);
                        return false;
                    }
                }
                else if (!skipUnknownValue(cursor, field, status))
                {
                    header = HeaderBlockView.init;
                    return false;
                }
                break;

            case 16:
                if (!decodeLastString(
                    cursor,
                    field,
                    decoded.writingProgram,
                    decoded.hasWritingProgram,
                    status))
                {
                    header = HeaderBlockView.init;
                    return false;
                }
                break;

            case 17:
                if (!decodeLastString(
                    cursor,
                    field,
                    decoded.source,
                    decoded.hasSource,
                    status))
                {
                    header = HeaderBlockView.init;
                    return false;
                }
                break;

            case 32:
                if (!decodeLastInt64(
                    cursor,
                    field,
                    decoded.replicationTimestamp,
                    decoded.hasReplicationTimestamp,
                    status))
                {
                    header = HeaderBlockView.init;
                    return false;
                }
                break;

            case 33:
                if (!decodeLastInt64(
                    cursor,
                    field,
                    decoded.replicationSequenceNumber,
                    decoded.hasReplicationSequenceNumber,
                    status))
                {
                    header = HeaderBlockView.init;
                    return false;
                }
                break;

            case 34:
                if (!decodeLastString(
                    cursor,
                    field,
                    decoded.replicationBaseUrl,
                    decoded.hasReplicationBaseUrl,
                    status))
                {
                    header = HeaderBlockView.init;
                    return false;
                }
                break;

            default:
                if (!skipUnknownValue(cursor, field, status))
                {
                    header = HeaderBlockView.init;
                    return false;
                }
                break;
        }
    }

    if (decoded.hasBBox)
    {
        if (!bbox.left)
            return failMissingBBox(PbfError.missingHeaderBBoxLeft, 1, input.length, header, status);
        if (!bbox.right)
            return failMissingBBox(PbfError.missingHeaderBBoxRight, 2, input.length, header, status);
        if (!bbox.top)
            return failMissingBBox(PbfError.missingHeaderBBoxTop, 3, input.length, header, status);
        if (!bbox.bottom)
            return failMissingBBox(PbfError.missingHeaderBBoxBottom, 4, input.length, header, status);

        decoded.bbox = bbox.value;
    }

    header = decoded;
    status = PbfStatus.init;
    return true;
}

private bool mergeHeaderBBox(
    const(ubyte)[] input,
    size_t baseOffset,
    ref HeaderBBoxAccumulator bbox,
    out PbfStatus status)
    @safe nothrow @nogc
{
    auto cursor = WireCursor(input);

    while (!cursor.empty)
    {
        FieldHeader field;
        WireStatus wire;
        if (!readFieldHeader(cursor, field, wire))
        {
            status = PbfStatus.fromHeaderBBoxWire(wire, baseOffset);
            return false;
        }

        if (field.number >= 1 && field.number <= 4 &&
            field.wireType == WireType.varint)
        {
            long value;
            if (!readSVarint64(cursor, value, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = field.number;
                status = PbfStatus.fromHeaderBBoxWire(wire, baseOffset);
                return false;
            }

            switch (field.number)
            {
                case 1:
                    bbox.value.left = value;
                    bbox.left = true;
                    break;
                case 2:
                    bbox.value.right = value;
                    bbox.right = true;
                    break;
                case 3:
                    bbox.value.top = value;
                    bbox.top = true;
                    break;
                case 4:
                    bbox.value.bottom = value;
                    bbox.bottom = true;
                    break;
                default:
                    break;
            }
        }
        else
        {
            if (!skipFieldValue(cursor, field, wire))
            {
                status = PbfStatus.fromHeaderBBoxWire(wire, baseOffset);
                return false;
            }
        }
    }

    status = PbfStatus.init;
    return true;
}

private bool decodeLastString(
    ref WireCursor cursor,
    FieldHeader field,
    ref const(ubyte)[] value,
    ref bool present,
    out PbfStatus status)
    @safe nothrow @nogc
{
    if (field.wireType != WireType.lengthDelimited)
        return skipUnknownValue(cursor, field, status);

    WireStatus wire;
    if (!readLengthDelimited(cursor, field.number, value, wire))
    {
        status = PbfStatus.fromHeaderBlockWire(wire);
        return false;
    }

    present = true;
    status = PbfStatus.init;
    return true;
}

private bool decodeLastInt64(
    ref WireCursor cursor,
    FieldHeader field,
    ref long value,
    ref bool present,
    out PbfStatus status)
    @safe nothrow @nogc
{
    if (field.wireType != WireType.varint)
        return skipUnknownValue(cursor, field, status);

    WireStatus wire;
    ulong encoded;
    if (!readVarint64(cursor, encoded, wire))
    {
        if (wire.fieldNumber == 0)
            wire.fieldNumber = field.number;
        status = PbfStatus.fromHeaderBlockWire(wire);
        return false;
    }

    value = cast(long)encoded;
    present = true;
    status = PbfStatus.init;
    return true;
}

private bool skipUnknownValue(
    ref WireCursor cursor,
    FieldHeader field,
    out PbfStatus status)
    @safe nothrow @nogc
{
    WireStatus wire;
    if (!skipFieldValue(cursor, field, wire))
    {
        status = PbfStatus.fromHeaderBlockWire(wire);
        return false;
    }

    status = PbfStatus.init;
    return true;
}

private bool failMissingBBox(
    PbfError error,
    uint bboxField,
    size_t offset,
    out HeaderBlockView header,
    out PbfStatus status)
    @safe pure nothrow @nogc
{
    header = HeaderBlockView.init;
    status = PbfStatus.failure(error, offset, bboxField);
    return false;
}

unittest
{
    // bbox: left=-1, right=2, top=3, bottom=-4
    // required: OsmSchema-V0.6, DenseNodes
    // optional: LocationsOnWays
    const(ubyte)[] bytes = [
        0x0a, 0x08,
            0x08, 0x01,
            0x10, 0x04,
            0x18, 0x06,
            0x20, 0x07,
        0x22, 0x0e,
            0x4f, 0x73, 0x6d, 0x53, 0x63, 0x68, 0x65,
            0x6d, 0x61, 0x2d, 0x56, 0x30, 0x2e, 0x36,
        0x22, 0x0a,
            0x44, 0x65, 0x6e, 0x73, 0x65, 0x4e, 0x6f, 0x64, 0x65, 0x73,
        0x2a, 0x0f,
            0x4c, 0x6f, 0x63, 0x61, 0x74, 0x69, 0x6f, 0x6e,
            0x73, 0x4f, 0x6e, 0x57, 0x61, 0x79, 0x73,
        0x82, 0x01, 0x03, 0x66, 0x6f, 0x6f,
        0x80, 0x02, 0x2a,
        0x88, 0x02, 0x07,
    ];

    HeaderBlockView header;
    PbfStatus status;
    assert(decodeHeaderBlock(bytes, header, status));
    assert(status.ok);
    assert(header.raw == bytes);
    assert(header.hasBBox);
    assert(header.bbox.left == -1);
    assert(header.bbox.right == 2);
    assert(header.bbox.top == 3);
    assert(header.bbox.bottom == -4);
    assert(header.hasWritingProgram);
    assert(header.replicationTimestamp == 42);
    assert(header.replicationSequenceNumber == 7);

    auto required = header.requiredFeatures;
    assert(!required.empty);
    assert(required.front.bytes.length == 14);
    required.popFront();
    assert(!required.empty);
    assert(required.front.bytes.length == 10);
    required.popFront();
    assert(required.empty);

    auto optional = header.optionalFeatures;
    assert(!optional.empty && optional.front.bytes.length == 15);
    optional.popFront();
    assert(optional.empty);
}

unittest
{
    // Singular embedded messages merge across repeated occurrences.
    const(ubyte)[] merged = [
        0x0a, 0x04, 0x08, 0x01, 0x10, 0x04,
        0x0a, 0x04, 0x18, 0x06, 0x20, 0x07,
    ];

    HeaderBlockView header;
    PbfStatus status;
    assert(decodeHeaderBlock(merged, header, status));
    assert(header.bbox.left == -1 && header.bbox.right == 2);
    assert(header.bbox.top == 3 && header.bbox.bottom == -4);

    const(ubyte)[] incomplete = [
        0x0a, 0x02, 0x08, 0x01,
    ];
    assert(!decodeHeaderBlock(incomplete, header, status));
    assert(status.error == PbfError.missingHeaderBBoxRight);
}

unittest
{
    // Unknown fixed32 field is skipped and preserved in raw. Singular strings
    // use last-one-wins.
    const(ubyte)[] bytes = [
        0x82, 0x01, 0x01, 0x41,
        0x25, 1, 2, 3, 4,
        0x82, 0x01, 0x01, 0x42,
    ];

    HeaderBlockView header;
    PbfStatus status;
    assert(decodeHeaderBlock(bytes, header, status));
    assert(header.raw == bytes);
    assert(header.hasWritingProgram);
    assert(header.writingProgram.length == 1);
    assert(header.writingProgram[0] == cast(ubyte)'B');
}
