#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPILER="${WIRE_FUZZ_COMPILER:-${DC:-dmd}}"

dub run \
  --root="$ROOT/tests/fuzz" \
  --config=wire-fuzz \
  --compiler="$COMPILER" \
  --build=debug \
  -- \
  --manifest "$ROOT/tests/fuzz/corpus/wire-seeds.tsv"
