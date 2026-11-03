# PBF round-trip qualification

M4 uses two independent checks.

The deterministic self-test builds an owned document containing exact
nanodegree coordinates, millisecond timestamps, duplicate tags/references,
LocationsOnWays, Relation members and metadata. It writes the document, reads
it back, compares the complete known semantic model, reproduces the generated
source byte-for-byte, edits the owned model and proves the edit survives a
second semantic rewrite.

Run it with:

```bash
dub run --root=tests/roundtrip --config=pbf-roundtrip -- --self-test
```

For real data, `run-pinned-roundtrip.sh` uses the repository's immutable
Geofabrik manifest. The D comparator verifies the complete owned model. Then
`osmium-tool`/libosmium independently parses both original and rewritten PBF
files; their sorted OPL element streams must be byte-identical.

```bash
sudo apt install osmium-tool
bash tests/roundtrip/run-pinned-roundtrip.sh monaco-260901 liechtenstein-260901
```

The default real-data set is Monaco plus Liechtenstein. Larger pinned datasets
may be supplied explicitly. Austria is intentionally not an ordinary M4 gate:
the current document API materializes the complete owned dataset and is not the
future compact-store/streaming writer benchmark.


## I/O boundary

This qualification executable uses ordinary file APIs only as test-harness
plumbing. The public `osm-d` library does not define filesystem or HTTP I/O.
Production byte-resource access belongs to `transport-d` (ADR 0019). Once its
v0.1.0 release is tagged and registry-resolvable, source/sink integration can be
qualified against that released contract without changing PBF semantics.


## M4 qualification evidence

The acceptance run on 2026-11-03 used commit
`0e307818521c4a249e032204a7c45be5001891d4` on GitHub-hosted Ubuntu 24.04,
LDC 1.41.0, DUB 1.40.0 and `osmium-tool` 1.16.0-1build1.

| dataset | input bytes | rewritten bytes | nodes | ways | relations | osm-d semantic comparator | libosmium OPL differential |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| monaco-260901 | 690,567 | 2,496,211 | 41,703 | 6,249 | 348 | PASS | PASS |
| liechtenstein-260901 | 3,451,831 | 17,477,466 | 361,543 | 42,051 | 973 | PASS | PASS |
| bremen-260901 | 21,159,666 | 91,571,257 | 1,662,874 | 328,626 | 5,985 | PASS | PASS |

The larger output is expected for this first semantic writer: it deliberately
uses regular Nodes and raw/uncompressed Blob payloads rather than DenseNodes and
compression. M4 qualifies correctness and loss-awareness, not write-side size
or throughput optimization.

Austria is not part of the M4 round-trip acceptance gate. The current
`PbfDocument` intentionally owns the complete semantic dataset and an exact raw
source copy; country-scale write-side memory/performance belongs with the later
direct-to-store/streaming work rather than being used to force a premature M4
optimization.
