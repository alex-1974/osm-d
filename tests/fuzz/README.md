# Wire malformed-input and fuzz harness

This harness exercises the lowest protobuf/PBF boundaries without treating
ordinary parser rejection as a crash. It covers:

- bounded `WireCursor` operations;
- varint and ZigZag scalar decoding;
- field-header and primitive field-value scanning;
- length-delimited payloads;
- `PrimitiveGroup` scanning, including packed, unpacked, repeated and
  segmented DenseNodes scalar forms;
- PBF file framing.

## Deterministic regression seeds

Fast CI runs the committed corpus:

```bash
bash tests/fuzz/run-wire-seeds.sh
```

`corpus/wire-seeds.tsv` contains both legal edge representations and known
malformed classes. Each row states whether the targeted parser must accept or
reject the bytes. Important new malformed classes found by broader fuzzing
should be reduced into this corpus or an ordinary module unittest.

## Raw-input mode

The same executable accepts one arbitrary binary file:

```bash
dub run --root=tests/fuzz --config=wire-fuzz --compiler=ldc2 -- \
  --raw /path/to/input.bin
```

Raw mode runs the bytes through every bounded target. Decode failures are
expected; the harness fails only when an internal progress/lifetime invariant
is violated or the process itself crashes. This file-oriented entry point can
be wrapped by coverage-guided fuzzers that substitute an input filename.

Long fuzz campaigns are intentionally not part of Fast CI. Fast CI keeps the
small deterministic corpus; broader campaigns are evidence work, and any
stable discovered class is distilled into a permanent regression.
