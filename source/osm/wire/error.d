/**
 * Allocation-free error reporting for the protobuf wire decoder.
 */
module osm.wire.error;

/// Errors that can be detected while decoding protobuf wire data.
enum WireError : ubyte
{
    none,
    truncatedInput,
    truncatedVarint,
    varintOverflow,
    invalidFieldNumber,
    invalidWireType,
    lengthOverflow,
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
    WireError error = WireError.none;
    size_t offset;
    uint fieldNumber;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == WireError.none;
    }

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
