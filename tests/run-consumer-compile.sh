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

    # Root imports may legitimately expose package dependencies. Ask DUB for
    # the actual compiler import flags instead of pretending the public root is
    # dependency-free while still keeping this as a compile-only DIP1000 probe.
    read -r -a import_flags <<< "$(dub describe \
        --root="$ROOT" \
        --compiler="$compiler" \
        --data=import-paths \
        --vquiet)"

    object="$TMPDIR/consumer-$(basename "$compiler").o"
    echo "=== CONSUMER COMPILE: $compiler ==="
    "$compiler" \
        -preview=dip1000 \
        -c \
        "${import_flags[@]}" \
        "$SOURCE" \
        -of="$object"
    echo "PASS: $compiler external consumer compile"

    store_object="$TMPDIR/store-consumer-$(basename "$compiler").o"
    echo "=== STORE CONSUMER COMPILE: $compiler ==="
    "$compiler" -preview=dip1000 -c "${import_flags[@]}" \
        "$ROOT/tests/compatibility/store_consumer.d" -of="$store_object"
    echo "PASS: $compiler store consumer compile"

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

    echo "=== VALIDATION DUB CONSUMER: $compiler ==="
    dub build \
        --root="$ROOT/tests/compatibility/validate-consumer" \
        --compiler="$compiler" \
        --build=debug \
        --force
    echo "PASS: $compiler upload validation DUB consumer compile"

    echo "=== TOPOLOGY DUB CONSUMER: $compiler ==="
    dub build \
        --root="$ROOT/tests/compatibility/topology-consumer" \
        --compiler="$compiler" \
        --build=debug \
        --force
    echo "PASS: $compiler topology DUB consumer compile"

    echo "=== UPLOAD RESULT DUB CONSUMER: $compiler ==="
    dub build \
        --root="$ROOT/tests/compatibility/upload-consumer" \
        --compiler="$compiler" \
        --build=debug \
        --force
    echo "PASS: $compiler diffResult upload consumer compile"

    echo "=== CAPABILITIES DUB CONSUMER: $compiler ==="
    dub build \
        --root="$ROOT/tests/compatibility/capabilities-consumer" \
        --compiler="$compiler" \
        --build=debug \
        --force
    echo "PASS: $compiler Editing API capabilities consumer compile"

    echo "=== RELEASE API DUB CONSUMER: $compiler ==="
    dub build \
        --root="$ROOT/tests/compatibility/release-consumer" \
        --compiler="$compiler" \
        --build=debug \
        --force
    echo "PASS: $compiler current release API consumer compile"
done
