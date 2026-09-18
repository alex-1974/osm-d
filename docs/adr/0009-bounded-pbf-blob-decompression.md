# ADR 0009: Bounded OSMPBF Blob decompression

- Status: Accepted
- Date: 2026-09-12

## Context

OSMPBF wraps each `HeaderBlock` or `PrimitiveBlock` in a storage-level `Blob`.
The canonical schema requires readers to support raw and zlib-wrapped payloads;
LZMA, LZ4, and Zstandard are optional, while field 5 is a deprecated bzip2
representation. Compressed Blobs carry `raw_size`, and the format requires the
uncompressed payload to remain below 32 MiB.

A generic convenience decompressor that grows its destination buffer until the
stream ends is unsuitable for untrusted PBF input: a false or missing size can
turn a compressed block into an unbounded allocation. It would also bypass the
streaming architecture's planned worker-local decompression buffers.

## Decision

`osm-d` separates Blob parsing from payload materialization.

`decodeBlob` is zero-copy and allocation-free. It validates one unambiguous
known payload representation, validates `raw_size`, preserves the complete
serialized Blob bytes, and recognizes optional/obsolete codecs even when no
backend is available.

Raw payloads remain borrowed directly from the serialized Blob.

Zlib payloads are decoded by `decodeBlobPayloadInto` into caller-owned storage.
The caller must provide at least the validated `raw_size` capacity. The zlib
backend receives exactly that output bound, and the result is accepted only if:

1. zlib reports success;
2. produced bytes equal `raw_size`; and
3. the complete `zlib_data` field was consumed, with no trailing bytes.

The implementation uses zlib's `uncompress2` API because it exposes both the
bounded destination size and consumed source length. No D GC allocation occurs
in the decompression module, allowing future worker-local pooled buffers.

LZMA, LZ4, and Zstandard are recognized but currently return an explicit
`unsupportedBlobCompression` status. Deprecated bzip2 returns a distinct
`obsoleteBlobCompression` status. Optional backends can be added later without
changing Blob parsing semantics.

Although protobuf oneof parsing normally applies last-one-wins semantics, the
validated Blob decoder rejects multiple correctly encoded payload occurrences.
Silently shadowing payload bytes would conflict with the project's no-silent-
loss invariant. The complete serialized Blob remains the lower-level lossless
representation for compatibility work.

## Consequences

- Raw PBF blocks remain zero-copy.
- Zlib decompression has a hard, schema-validated output bound.
- Decompression buffers can be pooled per worker instead of allocated per Blob.
- Corrupt `raw_size`, zlib bombs beyond the declared size, and trailing zlib
  bytes fail closed.
- Optional compression formats are visible rather than mistaken for malformed
  or unknown protobuf fields.
- Supporting another codec requires a backend implementation, not changes to
  the Blob wire decoder.

## References

- OpenStreetMap PBF format / `fileformat.proto`.
- `openstreetmap/OSM-binary` `max_uncompressed_blob_size` definition.
- D 2.111 / Phobos `etc.c.zlib` binding for zlib 1.3.1 and `uncompress2`.
