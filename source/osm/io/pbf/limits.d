/**
 * Resource and format limits used by the OSMPBF storage layer.
 *
 * The hard header and uncompressed-blob limits come from the canonical
 * OSM-binary implementation and the OSM PBF format documentation. The
 * serialized Blob-message limit additionally mirrors the reference Java
 * reader's defensive body-size check so streaming callers never have to
 * reserve an unbounded amount of memory from an untrusted `datasize` field.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.limits;

/** Recommended upper size for a serialized `BlobHeader` message. */
enum size_t recommendedBlobHeaderSize = 32 * 1024;

/**
 * Exclusive hard upper bound for a serialized `BlobHeader` message.
 *
 * A header length greater than or equal to this value is rejected. The PBF
 * format specifies that a BlobHeader must be smaller than 64 KiB.
 */
enum size_t maxBlobHeaderSize = 64 * 1024;

/** Recommended upper size for an uncompressed block payload. */
enum size_t recommendedUncompressedBlobSize = 16 * 1024 * 1024;

/**
 * Hard upper bound for an uncompressed block payload.
 *
 * Enforcement belongs to the Blob/decompression layer; it is defined here so
 * every stage uses the same limit.
 */
enum size_t maxUncompressedBlobSize = 32 * 1024 * 1024;

/**
 * Defensive upper bound for the serialized `Blob` message named by
 * `BlobHeader.datasize`.
 *
 * The canonical Java OSM-binary reader rejects serialized file-block bodies
 * larger than 32 MiB. Unlike `maxUncompressedBlobSize`, equality is accepted
 * here to match that reference-reader behavior.
 */
enum size_t maxSerializedBlobSize = 32 * 1024 * 1024;
