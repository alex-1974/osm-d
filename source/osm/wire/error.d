/**
 * Allocation-free error reporting for protobuf wire decoding.
 *
 * Low-level wire routines return compact status values instead of allocating
 * exceptions. Higher layers may translate these statuses into richer errors
 * outside benchmark-critical `@nogc` paths.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.wire.error;

/** Errors detected while decoding protobuf wire data. */
enum WireError : ubyte
{
    /// No error has occurred.
    none,
    /// A fixed-size or length-delimited value extends beyond the input buffer.
    truncatedInput,
    /// A varint terminates because the input buffer ended prematurely.
    truncatedVarint,
    /// A varint encodes a value outside the supported integer width.
    varintOverflow,
    /// A protobuf field number is zero or exceeds the 29-bit field-number limit.
    invalidFieldNumber,
    /// A field key uses a reserved or unknown protobuf wire type.
    invalidWireType,
    /// A length-delimited field length cannot be represented as `size_t`.
    lengthOverflow,
    /// A protobuf group was encountered where group decoding is not supported.
    unsupportedGroup,
}

/**
 * Error status returned by low-level decoding operations.
 *
 * `offset` is measured from the beginning of the current wire buffer.
 * `fieldNumber` is zero when no protobuf field has been established yet.
 */
struct WireStatus
{
    /// Error code; `WireError.none` denotes success.
    WireError error = WireError.none;
    /// Byte offset associated with the status.
    size_t offset;
    /// Protobuf field number associated with the status, or zero if unknown.
    uint fieldNumber;

    /** Returns `true` when `error == WireError.none`. */
    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == WireError.none;
    }

    /**
     * Construct a failed wire status.
     *
     * Params:
     *   error = Error code; must describe the failure.
     *   offset = Byte offset at which the failure was detected.
     *   fieldNumber = Associated protobuf field number, or zero if unavailable.
     *
     * Returns:
     *   A `WireStatus` containing the supplied failure information.
     */
    static WireStatus failure(WireError error, size_t offset, uint fieldNumber = 0)
        @safe pure nothrow @nogc
    {
        return WireStatus(error, offset, fieldNumber);
    }
}

unittest
{
    WireStatus status;
    assert(status.ok);

    status = WireStatus.failure(WireError.truncatedInput, 17, 3);
    assert(!status.ok);
    assert(status.offset == 17);
    assert(status.fieldNumber == 3);
}
