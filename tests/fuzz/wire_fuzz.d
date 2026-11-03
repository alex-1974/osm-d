/**
 * Deterministic seed and raw-input harness for osm-d wire/PBF boundaries.
 *
 * The seed mode checks known accept/reject classifications. Raw mode sends one
 * arbitrary byte buffer through bounded wire, repeated-scalar, PrimitiveGroup,
 * and PBF framing paths and treats parser errors as normal outcomes.
 */
module osm.tests.wire_fuzz;

import osm.io.pbf.error : PbfStatus;
import osm.io.pbf.framing :
    FileBlockView, FrameReadResult, readFileBlock;
import osm.io.pbf.primitive_group :
    PrimitiveGroupLayout, decodePrimitiveGroupLayout;
import osm.wire.cursor : WireCursor;
import osm.wire.error : WireStatus;
import osm.wire.field :
    FieldHeader, readFieldHeader, readLengthDelimited, skipFieldValue;
import osm.wire.varint :
    readSVarint32, readSVarint64, readVarint32, readVarint64;

import std.file : read, readText;
import std.stdio : stderr, writeln;
import std.string : split, splitLines, strip;

private bool fail(string message)
{
    stderr.writeln("FAIL: ", message);
    return false;
}

private int hexNibble(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return 10 + c - 'a';
    if (c >= 'A' && c <= 'F')
        return 10 + c - 'A';
    return -1;
}

private bool parseHex(string encoded, out ubyte[] bytes)
{
    encoded = encoded.strip;
    if (encoded == "-")
    {
        bytes = null;
        return true;
    }

    if ((encoded.length & 1) != 0)
        return fail("hex seed has odd length");

    bytes = new ubyte[encoded.length / 2];
    foreach (i; 0 .. bytes.length)
    {
        const hi = hexNibble(encoded[i * 2]);
        const lo = hexNibble(encoded[i * 2 + 1]);
        if (hi < 0 || lo < 0)
        {
            bytes = null;
            return fail("hex seed contains a non-hex character");
        }

        bytes[i] = cast(ubyte)((hi << 4) | lo);
    }

    return true;
}

private bool exerciseAll(scope const(ubyte)[] bytes)
{
    // Cursor primitives, including a deliberately sometimes-too-large take.
    auto cursor = WireCursor(bytes);
    if (!cursor.empty)
    {
        ubyte first;
        if (!cursor.readByte(first))
            return fail("non-empty cursor could not read its first byte");

        bool ok;
        const size_t requested =
            cast(size_t)(first % 8) + bytes.length;
        auto child = cursor.takeCursor(requested, ok);
        if (ok && child.remaining != requested)
            return fail("takeCursor returned the wrong bounded length");
    }

    // Each scalar decoder receives an independent cursor because advancing on
    // malformed input is part of its contract.
    {
        auto c = WireCursor(bytes);
        WireStatus status;
        ulong value;
        readVarint64(c, value, status);
    }
    {
        auto c = WireCursor(bytes);
        WireStatus status;
        uint value;
        readVarint32(c, value, status);
    }
    {
        auto c = WireCursor(bytes);
        WireStatus status;
        long value;
        readSVarint64(c, value, status);
    }
    {
        auto c = WireCursor(bytes);
        WireStatus status;
        int value;
        readSVarint32(c, value, status);
    }

    // A raw buffer is also a useful adversarial sequence of protobuf fields.
    // Every successful field must advance; failures terminate this attempt.
    {
        auto c = WireCursor(bytes);
        size_t steps;
        while (!c.empty)
        {
            const before = c.offset;
            FieldHeader header;
            WireStatus status;
            if (!readFieldHeader(c, header, status))
                break;
            if (!skipFieldValue(c, header, status))
                break;

            if (c.offset <= before)
                return fail("field scanner made no progress");
            if (++steps > bytes.length + 1)
                return fail("field scanner exceeded progress bound");
        }
    }

    // Exercise length decoding independently of a field key.
    {
        auto c = WireCursor(bytes);
        const(ubyte)[] payload;
        WireStatus status;
        readLengthDelimited(c, 1, payload, status);
    }

    // PrimitiveGroup scanning covers the legal packed, unpacked, repeated and
    // segmented scalar representations used by DenseNodes.
    {
        PrimitiveGroupLayout layout;
        PbfStatus status;
        decodePrimitiveGroupLayout(bytes, layout, status);
    }

    // Treat the same bytes as a sequence of file frames. A malformed frame is
    // a normal fuzz outcome, but every successful frame must advance.
    {
        auto c = WireCursor(bytes);
        ulong sequence;
        size_t steps;

        while (true)
        {
            const before = c.offset;
            FileBlockView block;
            PbfStatus status;
            const result =
                readFileBlock(c, sequence, block, status);

            if (result != FrameReadResult.block)
                break;

            if (c.offset <= before)
                return fail("PBF framing made no progress");
            if (++steps > bytes.length / 4 + 1)
                return fail("PBF framing exceeded progress bound");

            ++sequence;
        }
    }

    return true;
}

private bool checkExpected(
    string name,
    string mode,
    scope const(ubyte)[] bytes)
{
    if (mode == "any")
        return true;

    if (mode == "varint-reject")
    {
        auto c = WireCursor(bytes);
        WireStatus status;
        ulong value;
        return !readVarint64(c, value, status)
            || fail(name ~ ": malformed varint was accepted");
    }

    if (mode == "field-reject")
    {
        auto c = WireCursor(bytes);
        WireStatus status;
        FieldHeader header;
        return !readFieldHeader(c, header, status)
            || fail(name ~ ": invalid field header was accepted");
    }

    if (mode == "field-value-reject")
    {
        auto c = WireCursor(bytes);
        WireStatus status;
        FieldHeader header;
        if (!readFieldHeader(c, header, status))
            return fail(name ~ ": seed did not contain the expected field header");

        return !skipFieldValue(c, header, status)
            || fail(name ~ ": truncated fixed-width field was accepted");
    }

    if (mode == "frame-reject")
    {
        auto c = WireCursor(bytes);
        FileBlockView block;
        PbfStatus status;
        return readFileBlock(c, 0, block, status) == FrameReadResult.error
            || fail(name ~ ": malformed frame was not rejected");
    }

    if (mode == "group-accept")
    {
        PrimitiveGroupLayout layout;
        PbfStatus status;
        return decodePrimitiveGroupLayout(bytes, layout, status)
            || fail(name ~ ": legal PrimitiveGroup was rejected");
    }

    if (mode == "group-reject")
    {
        PrimitiveGroupLayout layout;
        PbfStatus status;
        return !decodePrimitiveGroupLayout(bytes, layout, status)
            || fail(name ~ ": invalid PrimitiveGroup was accepted");
    }

    return fail(name ~ ": unknown manifest mode " ~ mode);
}

private bool runManifest(string path)
{
    const text = readText(path);
    size_t count;

    foreach (rawLine; text.splitLines())
    {
        const line = rawLine.strip;
        if (line.length == 0 || line[0] == '#')
            continue;

        const parts = line.split("\t");
        if (parts.length != 3)
            return fail("manifest row must have name, mode, and hex columns");

        const name = parts[0].strip;
        const mode = parts[1].strip;

        ubyte[] bytes;
        if (!parseHex(parts[2], bytes))
            return false;

        if (!exerciseAll(bytes))
            return fail(name ~ ": invariant failure");
        if (!checkExpected(name, mode, bytes))
            return false;

        ++count;
    }

    if (count == 0)
        return fail("manifest contains no seeds");

    writeln("wire fuzz seeds: PASS (", count, " cases)");
    return true;
}

private void usage(string program)
{
    stderr.writeln(
        "usage: ", program,
        " --manifest <wire-seeds.tsv> | --raw <input-file>");
}

int main(string[] args)
{
    if (args.length != 3)
    {
        usage(args[0]);
        return 2;
    }

    if (args[1] == "--manifest")
        return runManifest(args[2]) ? 0 : 1;

    if (args[1] == "--raw")
    {
        auto raw = read(args[2]);
        const(ubyte)[] bytes = cast(ubyte[])raw;
        return exerciseAll(bytes) ? 0 : 1;
    }

    usage(args[0]);
    return 2;
}
