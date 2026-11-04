#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$ROOT/benchmark/datasets/geofabrik-2026-09-01.tsv"
DATA_DIR="${OSM_D_BENCH_DATA:-$ROOT/benchmark/data/geofabrik-2026-09-01}"
COMPILER="${ROUNDTRIP_COMPILER:-${DC:-ldc2}}"

if (($# == 0)); then
    set -- monaco-260901 liechtenstein-260901
fi

command -v osmium >/dev/null 2>&1 || {
    echo "required independent reference tool not found: osmium" >&2
    exit 2
}

"$ROOT/benchmark/fetch-datasets.sh" fetch "$@"

dub build \
    --root="$ROOT/tests/roundtrip" \
    --config=pbf-roundtrip \
    --compiler="$COMPILER" \
    --build=release \
    --force

BIN="$ROOT/tests/roundtrip/bin/osm-d-pbf-roundtrip"
[[ -x "$BIN" ]] || {
    echo "round-trip executable not found: $BIN" >&2
    exit 2
}

for id in "$@"; do
    filename=$(awk -F '\t' -v id="$id" \
        'NR > 1 && $1 == id { print $7; found = 1 } END { exit found ? 0 : 1 }' \
        "$MANIFEST")

    input="$DATA_DIR/$filename"
    tmpdir=$(mktemp -d "/tmp/osm-d-roundtrip-${id}.XXXXXX")
    output="$tmpdir/rewritten.osm.pbf"

    echo "=== ROUNDTRIP $id ==="
    "$BIN" "$input" "$output"

    # Independent parser validation through libosmium/osmium-tool.
    osmium fileinfo -e "$output" >/dev/null

    osmium cat "$input" -f opl | LC_ALL=C sort > "$tmpdir/input.opl"
    osmium cat "$output" -f opl | LC_ALL=C sort > "$tmpdir/output.opl"

    if ! cmp -s "$tmpdir/input.opl" "$tmpdir/output.opl"; then
        echo "FAIL: libosmium OPL semantic output differs for $id" >&2
        diff -u "$tmpdir/input.opl" "$tmpdir/output.opl" | head -200 >&2 || true
        rm -rf "$tmpdir"
        exit 1
    fi

    echo "differential_libosmium=PASS dataset=$id"
    rm -rf "$tmpdir"
done
