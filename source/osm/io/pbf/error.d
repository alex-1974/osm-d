/**
 * Allocation-free errors for the OSMPBF storage layer.
 *
 * Framing, BlobHeader, Blob, HeaderBlock, PrimitiveBlock, PrimitiveGroup,
 * DenseNodes, DenseInfo, DenseTags, StringTable, and decompression code use compact
 * status values
 * so malformed or hostile input can be rejected in `@nogc` paths. When a
 * protobuf wire decoder caused the failure, `wireError` preserves the lower-
 * level reason.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.error;

import osm.wire.error : WireError, WireStatus;

/** Errors detected while decoding OSMPBF storage/framing data. */
enum PbfError : ubyte
{
    /// No error has occurred.
    none,
    /// Fewer than four bytes remain for the network-order header length.
    truncatedHeaderLength,
    /// The serialized BlobHeader length violates the hard format limit.
    blobHeaderTooLarge,
    /// The input ends before the complete serialized BlobHeader is available.
    truncatedBlobHeader,
    /// The BlobHeader contains malformed or unsupported protobuf wire data.
    invalidBlobHeaderWire,
    /// The required BlobHeader `type` field is absent.
    missingBlobType,
    /// The required BlobHeader `datasize` field is absent.
    missingBlobDataSize,
    /// BlobHeader `datasize` is not a non-negative representable `int32`.
    invalidBlobDataSize,
    /// BlobHeader `datasize` exceeds the defensive serialized-Blob limit.
    blobDataTooLarge,
    /// The input ends before the complete serialized Blob message is available.
    truncatedBlobData,
    /// The Blob contains malformed or unsupported protobuf wire data.
    invalidBlobWire,
    /// No recognized Blob `data` payload field is present.
    missingBlobPayload,
    /// More than one correctly encoded Blob `data` oneof occurrence was found.
    multipleBlobPayloads,
    /// Blob `raw_size`, when present, is negative.
    invalidBlobRawSize,
    /// A compressed Blob does not provide the required `raw_size`.
    missingBlobRawSize,
    /// The uncompressed Blob payload reaches or exceeds the 32 MiB hard limit.
    uncompressedBlobTooLarge,
    /// Raw payload length disagrees with an explicitly supplied `raw_size`.
    blobRawSizeMismatch,
    /// The caller-provided decompression buffer is smaller than `raw_size`.
    outputBufferTooSmall,
    /// The optional compression representation has no configured backend.
    unsupportedBlobCompression,
    /// The Blob uses the deprecated bzip2 field.
    obsoleteBlobCompression,
    /// zlib rejected the compressed payload as malformed or otherwise invalid.
    zlibDecompressionFailed,
    /// Actual decompressed length disagrees with the declared `raw_size`.
    decompressedSizeMismatch,
    /// Bytes remain after the end of the single expected compressed stream.
    trailingCompressedData,
    /// The HeaderBlock contains malformed or unsupported protobuf wire data.
    invalidHeaderBlockWire,
    /// An embedded HeaderBBox contains malformed or unsupported protobuf wire data.
    invalidHeaderBBoxWire,
    /// A present HeaderBBox is missing required field `left`.
    missingHeaderBBoxLeft,
    /// A present HeaderBBox is missing required field `right`.
    missingHeaderBBoxRight,
    /// A present HeaderBBox is missing required field `top`.
    missingHeaderBBoxTop,
    /// A present HeaderBBox is missing required field `bottom`.
    missingHeaderBBoxBottom,
    /// The active reader policy does not understand a required HeaderBlock feature.
    unsupportedRequiredFeature,
    /// PrimitiveBlock payload reaches or exceeds the hard uncompressed block limit.
    primitiveBlockTooLarge,
    /// The PrimitiveBlock contains malformed or unsupported protobuf wire data.
    invalidPrimitiveBlockWire,
    /// The required PrimitiveBlock `stringtable` message is absent.
    missingPrimitiveBlockStringTable,
    /// A StringTable message contains malformed or unsupported protobuf wire data.
    invalidStringTableWire,
    /// The merged StringTable has no index-zero entry.
    missingStringTableZeroEntry,
    /// The merged StringTable index-zero entry is not empty.
    nonEmptyStringTableZeroEntry,
    /// Caller-owned StringRef storage is smaller than the validated table size.
    stringTableWorkspaceTooSmall,
    /// A defensive StringTable rescan did not reproduce the validated entry count.
    stringTableCountMismatch,
    /// The PrimitiveGroup contains malformed or unsupported protobuf wire data.
    invalidPrimitiveGroupWire,
    /// One PrimitiveGroup contains more than one OSMPBF primitive kind.
    mixedPrimitiveGroupTypes,
    /// A DenseNodes message contains malformed or unsupported protobuf wire data.
    invalidDenseNodesWire,
    /// A DenseInfo message contains malformed or unsupported protobuf wire data.
    invalidDenseInfoWire,
    /// DenseNodes ID, latitude and longitude columns have different lengths.
    denseNodeColumnLengthMismatch,
    /// Delta accumulation for a DenseNodes ID/coordinate column overflowed.
    denseNodeDeltaOverflow,
    /// Exact nanodegree coordinate conversion overflowed signed 64-bit range.
    denseNodeCoordinateOverflow,
    /// A present DenseInfo column does not contain one value per dense node.
    denseInfoColumnLengthMismatch,
    /// DenseInfo delta accumulation overflowed signed 64-bit range.
    denseInfoDeltaOverflow,
    /// Timestamp scaling by date_granularity overflowed signed 64-bit range.
    denseInfoTimestampOverflow,
    /// A cumulative DenseInfo uid cannot be represented by schema int32.
    denseInfoUidOutOfRange,
    /// A cumulative DenseInfo user_sid does not reference the indexed StringTable.
    denseInfoUserStringIdOutOfRange,
    /// A non-zero DenseNodes `keys_vals` entry cannot denote a positive int32 StringTable ID.
    invalidDenseTagStringId,
    /// A DenseNodes tag references a StringTable ID outside the indexed table.
    denseTagStringIdOutOfRange,
    /// A DenseNodes tag key is not followed by a value before its node delimiter.
    denseTagMissingValue,
    /// A non-empty DenseNodes tag stream has too few or too many node delimiters.
    denseTagNodeCountMismatch,
}

/**
 * Error status returned by PBF storage-layer decoders.
 *
 * `offset` is relative to the byte buffer supplied to the current public
 * decoding operation. `fieldNumber` is zero when no protobuf field is
 * associated with the failure. `wireError` is `WireError.none` unless the
 * failure originated in the generic protobuf wire layer.
 */
struct PbfStatus
{
    /// High-level PBF storage error; `PbfError.none` denotes success.
    PbfError error = PbfError.none;
    /// Byte offset associated with the failure.
    size_t offset;
    /// Protobuf field number in the current message, or zero if not applicable.
    uint fieldNumber;
    /// Underlying protobuf wire error, or `WireError.none`.
    WireError wireError = WireError.none;

    /** Returns `true` when no PBF storage error has occurred. */
    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == PbfError.none;
    }

    /**
     * Construct a PBF-layer failure.
     *
     * Params:
     *   error = High-level failure code.
     *   offset = Byte offset associated with the failure.
     *   fieldNumber = Protobuf field number, or zero if unavailable.
     *   wireError = Optional underlying protobuf wire error.
     *
     * Returns:
     *   A `PbfStatus` containing the supplied failure information.
     */
    static PbfStatus failure(
        PbfError error,
        size_t offset,
        uint fieldNumber = 0,
        WireError wireError = WireError.none)
        @safe pure nothrow @nogc
    {
        return PbfStatus(error, offset, fieldNumber, wireError);
    }

    /**
     * Translate a generic wire failure into a BlobHeader decoding failure.
     *
     * Params:
     *   wire = Lower-level wire status.
     *   baseOffset = Offset of the start of the wire buffer in the caller's
     *                coordinate system.
     *
     * Returns:
     *   A PBF status whose offset is translated by `baseOffset`.
     */
    static PbfStatus fromWire(WireStatus wire, size_t baseOffset = 0)
        @safe pure nothrow @nogc
    {
        return fromWireAs(PbfError.invalidBlobHeaderWire, wire, baseOffset);
    }

    /**
     * Translate a generic wire failure into a Blob decoding failure.
     *
     * Params:
     *   wire = Lower-level wire status.
     *   baseOffset = Offset of the start of the Blob wire buffer in the
     *                caller's coordinate system.
     *
     * Returns:
     *   A PBF status whose offset is translated by `baseOffset`.
     */
    static PbfStatus fromBlobWire(WireStatus wire, size_t baseOffset = 0)
        @safe pure nothrow @nogc
    {
        return fromWireAs(PbfError.invalidBlobWire, wire, baseOffset);
    }

    /** Translate a generic wire failure into a HeaderBlock decoding failure. */
    static PbfStatus fromHeaderBlockWire(WireStatus wire, size_t baseOffset = 0)
        @safe pure nothrow @nogc
    {
        return fromWireAs(PbfError.invalidHeaderBlockWire, wire, baseOffset);
    }

    /** Translate a generic wire failure inside an embedded HeaderBBox. */
    static PbfStatus fromHeaderBBoxWire(WireStatus wire, size_t baseOffset = 0)
        @safe pure nothrow @nogc
    {
        return fromWireAs(PbfError.invalidHeaderBBoxWire, wire, baseOffset);
    }

    /** Translate a generic wire failure into a PrimitiveBlock decoding failure. */
    static PbfStatus fromPrimitiveBlockWire(WireStatus wire, size_t baseOffset = 0)
        @safe pure nothrow @nogc
    {
        return fromWireAs(PbfError.invalidPrimitiveBlockWire, wire, baseOffset);
    }

    /** Translate a generic wire failure inside a StringTable message. */
    static PbfStatus fromStringTableWire(WireStatus wire, size_t baseOffset = 0)
        @safe pure nothrow @nogc
    {
        return fromWireAs(PbfError.invalidStringTableWire, wire, baseOffset);
    }

    /** Translate a generic wire failure into a PrimitiveGroup decoding failure. */
    static PbfStatus fromPrimitiveGroupWire(WireStatus wire, size_t baseOffset = 0)
        @safe pure nothrow @nogc
    {
        return fromWireAs(PbfError.invalidPrimitiveGroupWire, wire, baseOffset);
    }

    /** Translate a generic wire failure inside a DenseNodes message. */
    static PbfStatus fromDenseNodesWire(WireStatus wire, size_t baseOffset = 0)
        @safe pure nothrow @nogc
    {
        return fromWireAs(PbfError.invalidDenseNodesWire, wire, baseOffset);
    }

    /** Translate a generic wire failure inside a DenseInfo message. */
    static PbfStatus fromDenseInfoWire(WireStatus wire, size_t baseOffset = 0)
        @safe pure nothrow @nogc
    {
        return fromWireAs(PbfError.invalidDenseInfoWire, wire, baseOffset);
    }

private:
    static PbfStatus fromWireAs(
        PbfError error,
        WireStatus wire,
        size_t baseOffset)
        @safe pure nothrow @nogc
    {
        return PbfStatus.failure(
            error,
            baseOffset + wire.offset,
            wire.fieldNumber,
            wire.error);
    }
}

unittest
{
    PbfStatus status;
    assert(status.ok);

    WireStatus wire = WireStatus.failure(WireError.truncatedVarint, 3, 1);
    status = PbfStatus.fromWire(wire, 10);
    assert(!status.ok);
    assert(status.error == PbfError.invalidBlobHeaderWire);
    assert(status.offset == 13);
    assert(status.fieldNumber == 1);
    assert(status.wireError == WireError.truncatedVarint);

    status = PbfStatus.fromBlobWire(wire, 20);
    assert(status.error == PbfError.invalidBlobWire);
    assert(status.offset == 23);

    status = PbfStatus.fromHeaderBlockWire(wire, 30);
    assert(status.error == PbfError.invalidHeaderBlockWire);
    assert(status.offset == 33);

    status = PbfStatus.fromHeaderBBoxWire(wire, 40);
    assert(status.error == PbfError.invalidHeaderBBoxWire);
    assert(status.offset == 43);

    status = PbfStatus.fromPrimitiveBlockWire(wire, 50);
    assert(status.error == PbfError.invalidPrimitiveBlockWire);
    assert(status.offset == 53);

    status = PbfStatus.fromStringTableWire(wire, 60);
    assert(status.error == PbfError.invalidStringTableWire);
    assert(status.offset == 63);

    status = PbfStatus.fromPrimitiveGroupWire(wire, 70);
    assert(status.error == PbfError.invalidPrimitiveGroupWire);
    assert(status.offset == 73);

    status = PbfStatus.fromDenseNodesWire(wire, 80);
    assert(status.error == PbfError.invalidDenseNodesWire);
    assert(status.offset == 83);

    status = PbfStatus.fromDenseInfoWire(wire, 90);
    assert(status.error == PbfError.invalidDenseInfoWire);
    assert(status.offset == 93);
}
