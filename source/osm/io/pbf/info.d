/**
 * Allocation-free semantic decoding of regular OSMPBF `Info` metadata.
 *
 * Singular Info scalar fields follow protobuf last-one-wins semantics.
 * Repeated occurrences of the singular embedded `Info` field are merged by
 * invoking `mergeInfoMessage` in wire order. Presence is preserved separately
 * from schema defaults, and StringTable/timestamp semantics are finalized only
 * after the complete merged message has been seen.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-13
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.info;

import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.primitive_block : PrimitiveBlockLayout;
import osm.io.pbf.string_table : StringTableView;
import osm.util.checked : checkedMulAdd;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader,
    WireType,
    readFieldHeader,
    skipFieldValue;
import osm.wire.varint : readVarint64;

/** Semantic view of one merged regular OSMPBF `Info` message. */
struct InfoView
{
    /// Whether version was explicitly present.
    bool hasVersion;
    /// Version value; protobuf schema default is -1 when absent.
    int version_ = -1;

    /// Whether timestamp was explicitly present.
    bool hasTimestamp;
    /// Raw PBF timestamp value before `date_granularity` scaling.
    long timestampValue;
    /// Exact timestamp in milliseconds since the Unix epoch.
    long timestampMillis;

    /// Whether changeset was explicitly present.
    bool hasChangeset;
    /// Changeset identifier.
    long changeset;

    /// Whether uid was explicitly present.
    bool hasUid;
    /// OSM user identifier.
    int uid;

    /// Whether user_sid was explicitly present.
    bool hasUser;
    /// Final protobuf uint32 StringTable ID.
    uint userSid;
    /// Borrowed username bytes from the PrimitiveBlock StringTable.
    const(ubyte)[] user;

    /// Whether visible was explicitly present.
    bool hasVisible;
    /// Decoded protobuf boolean when `hasVisible` is true.
    bool visible;

private:
    size_t _timestampOffset;
    size_t _userSidOffset;
}

/**
 * Merge one serialized `Info` occurrence into an existing semantic view.
 *
 * Call this once for every correctly encoded occurrence of the singular
 * embedded Info field, in original wire order. Duplicate singular scalars use
 * protobuf last-one-wins semantics. Unknown fields and known fields with a
 * different wire type remain part of the authoritative raw message and are
 * skipped semantically.
 */
bool mergeInfoMessage(
    const(ubyte)[] input,
    size_t baseOffset,
    ref InfoView info,
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
            status = PbfStatus.fromInfoWire(wire, baseOffset);
            return false;
        }

        if (field.number >= 1 && field.number <= 6 &&
            field.wireType == WireType.varint)
        {
            const valueOffset = baseOffset + cursor.offset;
            ulong raw;
            if (!readVarint64(cursor, raw, wire))
            {
                if (wire.fieldNumber == 0)
                    wire.fieldNumber = field.number;
                status = PbfStatus.fromInfoWire(wire, baseOffset);
                return false;
            }

            switch (field.number)
            {
                case 1:
                    info.hasVersion = true;
                    info.version_ = cast(int)raw;
                    break;

                case 2:
                    info.hasTimestamp = true;
                    info.timestampValue = cast(long)raw;
                    info._timestampOffset = valueOffset;
                    break;

                case 3:
                    info.hasChangeset = true;
                    info.changeset = cast(long)raw;
                    break;

                case 4:
                    info.hasUid = true;
                    info.uid = cast(int)raw;
                    break;

                case 5:
                    // Protobuf uint32 parsing keeps the low 32 bits.
                    info.hasUser = true;
                    info.userSid = cast(uint)raw;
                    info._userSidOffset = valueOffset;
                    break;

                case 6:
                    info.hasVisible = true;
                    info.visible = raw != 0;
                    break;

                default:
                    assert(0, "unexpected Info field");
            }
            continue;
        }

        if (!skipFieldValue(cursor, field, wire))
        {
            status = PbfStatus.fromInfoWire(wire, baseOffset);
            return false;
        }
    }

    status = PbfStatus.init;
    return true;
}

/**
 * Finalize one completely merged regular Info view.
 *
 * Timestamp scaling and StringTable lookup intentionally happen only after all
 * duplicate Info/scalar occurrences have been merged. A superseded scalar
 * therefore cannot incorrectly invalidate the final protobuf semantic value.
 */
bool finalizeInfo(
    ref const PrimitiveBlockLayout block,
    StringTableView table,
    ref InfoView info,
    out PbfStatus status)
    @safe nothrow @nogc
{
    if (info.hasTimestamp)
    {
        long millis;
        if (!checkedMulAdd(
            0,
            cast(long)block.dateGranularity,
            info.timestampValue,
            millis))
        {
            status = PbfStatus.failure(
                PbfError.infoTimestampOverflow,
                info._timestampOffset,
                2);
            return false;
        }
        info.timestampMillis = millis;
    }

    if (info.hasUser)
    {
        const(ubyte)[] user;
        if (!table.get(cast(size_t)info.userSid, user))
        {
            status = PbfStatus.failure(
                PbfError.infoUserStringIdOutOfRange,
                info._userSidOffset,
                5);
            return false;
        }
        info.user = user;
    }

    status = PbfStatus.init;
    return true;
}

unittest
{
    import osm.io.pbf.string_table : StringRef;

    PrimitiveBlockLayout block;
    block.dateGranularity = 1000;

    const(ubyte)[] strings = [0, 'a', 'b'];
    StringRef[3] refs = [
        StringRef(0, 0),
        StringRef(1, 1),
        StringRef(2, 1),
    ];
    StringTableView table = StringTableView(strings, refs[]);

    InfoView info;
    PbfStatus status;

    // First embedded occurrence.
    const(ubyte)[] first = [
        0x08, 0x01,       // version = 1
        0x10, 0x0a,       // timestamp = 10
        0x28, 0x01,       // user_sid = 1
        0x30, 0x00,       // visible = false
    ];
    assert(mergeInfoMessage(first, 100, info, status));

    // A later embedded occurrence merges; duplicate scalars use last-one-wins.
    const(ubyte)[] second = [
        0x08, 0x07,       // version = 7
        0x18, 0x2a,       // changeset = 42
        0x20, 0x09,       // uid = 9
        0x28, 0x02,       // user_sid = 2
        0x30, 0x01,       // visible = true
    ];
    assert(mergeInfoMessage(second, 200, info, status));
    assert(finalizeInfo(block, table, info, status));

    assert(info.hasVersion && info.version_ == 7);
    assert(info.hasTimestamp && info.timestampValue == 10);
    assert(info.timestampMillis == 10_000);
    assert(info.hasChangeset && info.changeset == 42);
    assert(info.hasUid && info.uid == 9);
    assert(info.hasUser && info.userSid == 2);
    const(ubyte)[] b = ['b'];
    assert(info.user == b);
    assert(info.hasVisible && info.visible);
}

unittest
{
    import osm.io.pbf.string_table : StringRef;

    PrimitiveBlockLayout block;
    block.dateGranularity = 2;

    const(ubyte)[] strings = [0];
    StringRef[1] refs = [StringRef(0, 0)];
    StringTableView table = StringTableView(strings, refs[]);

    InfoView info;
    PbfStatus status;

    // long.max as an int64 protobuf value, then scaling by 2 overflows.
    const(ubyte)[] timestamp = [
        0x10,
        0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0x7f
    ];
    assert(mergeInfoMessage(timestamp, 0, info, status));
    assert(!finalizeInfo(block, table, info, status));
    assert(status.error == PbfError.infoTimestampOverflow);
    assert(status.fieldNumber == 2);
}

unittest
{
    import osm.io.pbf.string_table : StringRef;

    PrimitiveBlockLayout block;
    const(ubyte)[] strings = [0, 'x'];
    StringRef[2] refs = [StringRef(0, 0), StringRef(1, 1)];
    StringTableView table = StringTableView(strings, refs[]);

    InfoView info;
    PbfStatus status;

    const(ubyte)[] invalidUser = [0x28, 0x02];
    assert(mergeInfoMessage(invalidUser, 50, info, status));
    assert(!finalizeInfo(block, table, info, status));
    assert(status.error == PbfError.infoUserStringIdOutOfRange);
    assert(status.fieldNumber == 5);
}
