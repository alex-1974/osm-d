#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
read -r -a compilers <<< "${EXAMPLE_COMPILERS:-dmd ldc2}"

examples=(pbf-read pbf-store pbf-roundtrip xml-roundtrip osmchange-roundtrip)

for compiler in "${compilers[@]}"; do
  command -v "$compiler" >/dev/null 2>&1 || {
    echo "required compiler not found: $compiler" >&2
    exit 2
  }

  for example in "${examples[@]}"; do
    echo "=== EXAMPLE: $example ($compiler) ==="
    dub build --root="$ROOT/examples/$example" --compiler="$compiler" \
      --build=debug --force
  done
done
