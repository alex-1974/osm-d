#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/tests/compatibility/pbf_reader_consumer.d"
TMPDIR="$(mktemp -d /tmp/osm-d-consumer-compile.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

read -r -a compilers <<< "${CONSUMER_COMPILERS:-dmd ldc2}"

for compiler in "${compilers[@]}"; do
    command -v "$compiler" >/dev/null 2>&1 || {
        echo "required compiler not found: $compiler" >&2
        exit 2
    }

    object="$TMPDIR/consumer-$(basename "$compiler").o"
    echo "=== CONSUMER COMPILE: $compiler ==="
    "$compiler" \
        -preview=dip1000 \
        -c \
        -I"$ROOT/source" \
        "$SOURCE" \
        -of="$object"
    echo "PASS: $compiler external consumer compile"

    echo "=== XML DUB CONSUMER: $compiler ==="
    dub build \
        --root="$ROOT/tests/compatibility/xml-consumer" \
        --compiler="$compiler" \
        --build=debug \
        --force
    echo "PASS: $compiler XML DUB consumer compile"

    echo "=== OSMCHANGE DUB CONSUMER: $compiler ==="
    dub build \
        --root="$ROOT/tests/compatibility/osmchange-consumer" \
        --compiler="$compiler" \
        --build=debug \
        --force
    echo "PASS: $compiler osmChange DUB consumer compile"
done
