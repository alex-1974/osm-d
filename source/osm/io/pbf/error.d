/**
 * Allocation-free errors for the OSMPBF storage layer.
 *
 * Framing, BlobHeader, Blob, and decompression code use compact status values
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
}
