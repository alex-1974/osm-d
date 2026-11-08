/**
 * Internal bounded transport adapters used by the OSM XML codec.
 *
 * XmlCharRange turns an absolute-position transport-d ByteSource into the
 * ForwardRange<char> required by dxml. Saved cursors copy only an absolute
 * offset; previously consumed input is not retained. A shared fixed-size cache
 * may re-read older positions when dxml traverses a saved range.
 *
 * XmlSinkOutput buffers dxml character output before writing it to a
 * transport-d ByteSink.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.xml.byte_range;

import transport.source :
    ByteSink,
    ByteSource,
    ReadError,
    ReadLimits,
    WriteError,
    WriteLimits;

package(osm):

private enum size_t defaultXmlBufferSize = 64 * 1024;

final class XmlSourceException : Exception
{
    ReadError error;
    ulong offset;

    this(ReadError error, ulong offset) @safe
    {
        this.error = error;
        this.offset = offset;
        super("OSM XML transport read failed");
    }
}

final class XmlSinkException : Exception
{
    WriteError error;

    this(WriteError error) @safe
    {
        this.error = error;
        super("OSM XML transport write failed");
    }
}

private final class XmlSourceCache
{
    private ByteSource source;
    private ubyte[] buffer;
    private ulong blockOffset;
    private size_t blockLength;
    private bool blockLoaded;
    private bool eofKnown;
    private ulong eofOffset;

    this(ByteSource source, size_t requestedBufferSize) @safe
    {
        this.source = source;
        const size = requestedBufferSize == 0
            ? defaultXmlBufferSize
            : requestedBufferSize;
        buffer = new ubyte[size];
    }

    bool byteAt(ulong absoluteOffset, out char value) @safe
    {
        if (eofKnown && absoluteOffset >= eofOffset)
            return false;

        if (blockLoaded &&
            absoluteOffset >= blockOffset &&
            absoluteOffset - blockOffset < blockLength)
        {
            value = cast(char) buffer[cast(size_t)(absoluteOffset - blockOffset)];
            return true;
        }

        const width = cast(ulong) buffer.length;
        const alignedOffset = (absoluteOffset / width) * width;

        auto result = source.readSome(
            alignedOffset,
            buffer[],
            ReadLimits(buffer.length));

        if (result.hasError &&
            result.error.kind == ReadError.endOfSource)
        {
            eofKnown = true;
            eofOffset = alignedOffset;
            blockLoaded = false;
            blockLength = 0;
            return false;
        }

        if (result.hasError)
            throw new XmlSourceException(result.error.kind, alignedOffset);

        if (result.value.bytesRead == 0)
            throw new XmlSourceException(ReadError.sourceFailure, alignedOffset);

        blockOffset = alignedOffset;
        blockLength = result.value.bytesRead;
        blockLoaded = true;

        if (blockLength < buffer.length)
        {
            eofKnown = true;
            eofOffset = blockOffset + blockLength;
        }

        if (absoluteOffset - blockOffset >= blockLength)
            return false;

        value = cast(char) buffer[cast(size_t)(absoluteOffset - blockOffset)];
        return true;
    }
}

/**
 * ForwardRange<char> over a ByteSource.
 *
 * The underlying byte resource must remain stable for the lifetime of the
 * parse. save() is O(1) and does not retain historical byte chunks.
 */
struct XmlCharRange
{
private:
    XmlSourceCache cache;
    ulong absoluteOffset;

public:
    this(ByteSource source, size_t bufferSize = 0, ulong startOffset = 0) @safe
    {
        cache = new XmlSourceCache(source, bufferSize);
        absoluteOffset = startOffset;
    }

    @property bool empty() @safe
    {
        char value;
        return !cache.byteAt(absoluteOffset, value);
    }

    @property char front() @safe
    {
        char value;
        const available = cache.byteAt(absoluteOffset, value);
        assert(available, "front called on empty XmlCharRange");
        return value;
    }

    void popFront() @safe
    {
        assert(!empty, "popFront called on empty XmlCharRange");
        ++absoluteOffset;
    }

    @property XmlCharRange save() @safe nothrow
    {
        return this;
    }

    @property ulong position() const @safe pure nothrow @nogc
    {
        return absoluteOffset;
    }
}

/** Buffered character output range backed by a ByteSink. */
final class XmlSinkOutput
{
private:
    ByteSink sink;
    ubyte[] buffer;
    size_t used;

public:
    this(ByteSink sink, size_t requestedBufferSize = 0) @safe
    {
        this.sink = sink;
        const size = requestedBufferSize == 0
            ? defaultXmlBufferSize
            : requestedBufferSize;
        buffer = new ubyte[size];
    }

    void put(char value) @safe
    {
        if (used == buffer.length)
            flush();

        buffer[used++] = cast(ubyte) value;
    }

    void flush() @safe
    {
        if (used == 0)
            return;

        auto result = sink.write(
            buffer[0 .. used],
            WriteLimits(used));

        if (result.hasError || result.value.bytesWritten != used)
        {
            const error = result.hasError
                ? result.error.kind
                : WriteError.destinationFailure;
            throw new XmlSinkException(error);
        }

        used = 0;
    }
}

unittest
{
    import std.range.primitives : isForwardRange;
    import transport.source : MemorySource;

    static assert(isForwardRange!XmlCharRange);

    const ubyte[] bytes = cast(const(ubyte)[])"abcdef";
    auto source = new MemorySource(bytes);
    auto range = XmlCharRange(source, 2);

    assert(range.front == 'a');
    range.popFront();

    auto saved = range.save;
    range.popFront();
    range.popFront();

    assert(range.front == 'd');
    assert(saved.front == 'b');
    saved.popFront();
    assert(saved.front == 'c');
}

unittest
{
    import transport.source : MemorySink;

    auto sink = new MemorySink();
    auto output = new XmlSinkOutput(sink, 2);

    output.put('a');
    output.put('b');
    output.put('c');
    output.flush();

    assert(sink.data == cast(const(ubyte)[])"abc");
}
