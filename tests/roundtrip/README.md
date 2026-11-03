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
tests/roundtrip/run-pinned-roundtrip.sh monaco-260901 liechtenstein-260901
```

The default real-data set is Monaco plus Liechtenstein. Larger pinned datasets
may be supplied explicitly. Austria is intentionally not an ordinary M4 gate:
the current document API materializes the complete owned dataset and is not the
future compact-store/streaming writer benchmark.
