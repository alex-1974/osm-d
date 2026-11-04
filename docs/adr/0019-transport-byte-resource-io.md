# ADR 0019: byte-resource I/O belongs to transport-d

- Status: Accepted
- Date: 2026-11-03
- Related: #44, #55, #56
- External package: `alex-1974/transport-d`

## Context

M4 adds durable PBF read/modify/write semantics. That work needs byte input and
output, but filesystem, HTTP, range access, sequential stream adaptation,
transport limits, provenance and transport errors are not OSM or PBF semantics.

The workspace already has `transport-d` for exactly that role. Its synchronous
contract exposes bounded `ByteSource`/`ByteSink` access and
`ByteReader`/`ByteWriter` adapters while keeping parsing and format semantics
in the consumer library.

`transport-d` v0.1.1 is now tagged and registry-resolvable. Its published
`ByteSource.readSome` contract provides bounded partial reads with explicit
EOF semantics, which is the refill primitive required by the streaming XML
adapter.

## Decision

`osm-d` does not implement its own file, HTTP, range, stream, retry, cache or
scheduler abstraction.

The PBF layer owns only format work:

- decoding bytes into borrowed or owned OSM/PBF semantics;
- preserving source bytes required by the loss-awareness contract;
- encoding semantic PBF output bytes;
- format-specific size, feature and integrity validation.

External resource transport belongs to `transport-d`:

- file and memory sources/sinks;
- HTTP Range GET / PUT;
- bounded transfer limits;
- source provenance and transport errors;
- sequential reader/writer adaptation;
- future executor-injected asynchronous transport.

The current whole-buffer PBF API remains valid. A future source/sink adapter
will target the published `transport-d` contract rather than introduce a
parallel I/O hierarchy in `osm-d`.

## Dependency timing

The release condition is now satisfied. M5 adds a hard DUB dependency on
`transport-d ~>0.1.1` and qualifies the released package through ordinary
`osm-d` CI. XML readers consume `ByteSource`; XML writers consume
`ByteSink`. No parallel file/network abstraction is introduced in `osm-d`.

## Tests and tools

Repository qualification tools may use ordinary process/file APIs as harness
plumbing. That does not establish a public `osm-d` I/O API. Production
consumer-facing file/network/resource access should use `transport-d`.

## Consequences

- one workspace-wide vocabulary exists for byte-resource access;
- PBF correctness remains independent of filesystem or HTTP policy;
- `osm-d` avoids duplicated FileSource/FileSink/HTTP/async abstractions;
- M4 completed without prematurely pinning an unreleased dependency;
- M5 XML streaming uses the released transport contract directly;
- future streaming PBF/store work has the same explicit transport boundary.
