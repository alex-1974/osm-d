/**
 * Compression identifiers used by OSMPBF `Blob` payloads.
 *
 * The enumeration mirrors the data members of the `Blob.data` oneof from
 * `fileformat.proto`. Raw and zlib payloads are mandatory reader capabilities;
 * LZMA, LZ4, and Zstandard are optional codecs. The former bzip2 field remains
 * recognizable so deprecated input is never mistaken for an unknown field.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.compression;

/** Compression/storage representation selected by an OSMPBF Blob. */
enum BlobCodec : ubyte
{
    /// No recognized payload field was selected.
    none,
    /// Field 1: uncompressed payload bytes.
    raw,
    /// Field 3: zlib-wrapped DEFLATE payload.
    zlib,
    /// Field 4: optional LZMA payload.
    lzma,
    /// Field 5: deprecated bzip2 payload; must never be reused.
    obsoleteBzip2,
    /// Field 6: optional LZ4 payload.
    lz4,
    /// Field 7: optional Zstandard payload.
    zstd,
}

/**
 * Return the protobuf field number carrying `codec`.
 *
 * Params:
 *   codec = Blob payload representation.
 *
 * Returns:
 *   The `Blob` field number, or zero for `BlobCodec.none`.
 */
uint blobPayloadFieldNumber(BlobCodec codec) @safe pure nothrow @nogc
{
    final switch (codec)
    {
        case BlobCodec.none: return 0;
        case BlobCodec.raw: return 1;
        case BlobCodec.zlib: return 3;
        case BlobCodec.lzma: return 4;
        case BlobCodec.obsoleteBzip2: return 5;
        case BlobCodec.lz4: return 6;
        case BlobCodec.zstd: return 7;
    }
}

/**
 * Return whether `codec` requires decompression before OSM protobuf decoding.
 */
bool isCompressed(BlobCodec codec) @safe pure nothrow @nogc
{
    return codec != BlobCodec.none && codec != BlobCodec.raw;
}

/**
 * Return whether the current core can produce uncompressed bytes for `codec`.
 *
 * Raw and zlib are supported because OSMPBF requires both from every reader.
 * Optional codecs are recognized but intentionally delegated to future
 * pluggable backends.
 */
bool isCodecSupported(BlobCodec codec) @safe pure nothrow @nogc
{
    return codec == BlobCodec.raw || codec == BlobCodec.zlib;
}

unittest
{
    assert(blobPayloadFieldNumber(BlobCodec.raw) == 1);
    assert(blobPayloadFieldNumber(BlobCodec.zstd) == 7);
    assert(!isCompressed(BlobCodec.raw));
    assert(isCompressed(BlobCodec.zlib));
    assert(isCodecSupported(BlobCodec.raw));
    assert(isCodecSupported(BlobCodec.zlib));
    assert(!isCodecSupported(BlobCodec.lz4));
}
