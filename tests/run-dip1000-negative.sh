#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$ROOT/tests/compile-fail/dip1000"

TMPDIR="$(mktemp -d /tmp/osm-d-dip1000-negative.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

failures=0

run_negative()
{
    local compiler="$1"
    local source="$2"
    local diagnostic_pattern="$3"

    local base
    local compiler_id
    local log
    local object

    base="$(basename "$source" .d)"
    compiler_id="$(basename "$compiler")"
    log="$TMPDIR/${base}-${compiler_id}.log"
    object="$TMPDIR/${base}-${compiler_id}.o"

    if "$compiler" \
        -preview=dip1000 \
        -c \
        "${IMPORT_FLAGS[@]}" \
        "$source" \
        -of="$object" \
        >"$log" 2>&1
    then
        printf 'FAIL  %-4s  %s unexpectedly compiled\n' \
            "$compiler" "$(basename "$source")"
        failures=$((failures + 1))
        return
    fi

    if ! grep -Eq "$diagnostic_pattern" "$log"; then
        printf 'FAIL  %-4s  %s failed for an unexpected reason\n' \
            "$compiler" "$(basename "$source")"
        sed -n '1,20p' "$log" | sed 's/^/      /'
        failures=$((failures + 1))
        return
    fi

    printf 'PASS  %-4s  %s rejected expected lifetime escape\n' \
        "$compiler" "$(basename "$source")"
}

read -r -a compilers <<< "${DIP1000_COMPILERS:-dmd ldc2}"

for compiler in "${compilers[@]}"; do
    command -v "$compiler" >/dev/null 2>&1 || {
        echo "required compiler not found: $compiler" >&2
        exit 2
    }

    read -r -a IMPORT_FLAGS <<< "$(dub describe \
        --root="$ROOT" \
        --compiler="$compiler" \
        --data=import-paths \
        --vquiet)"

    run_negative \
        "$compiler" \
        "$CASES/wire_cursor_escape.d" \
        'local variable|non-scope member function|WireCursor\(local\[\]\)'

    run_negative \
        "$compiler" \
        "$CASES/blob_header_escape.d" \
        'local variable|non-scope parameter|decodeBlobHeader\(local\[\]'

    run_negative \
        "$compiler" \
        "$CASES/string_table_escape.d" \
        'returning scope variable|return table'

    run_negative \
        "$compiler" \
        "$CASES/node_iterable_input_escape.d" \
        'local variable|scope|escape|return'

    run_negative \
        "$compiler" \
        "$CASES/node_foreach_view_escape.d" \
        'scope|escape|local variable|lifetime|address'

    run_negative \
        "$compiler" \
        "$CASES/way_iterable_input_escape.d" \
        'local variable|scope|escape|return'

    run_negative \
        "$compiler" \
        "$CASES/relation_iterable_input_escape.d" \
        'local variable|scope|escape|return'

    run_negative \
        "$compiler" \
        "$CASES/way_foreach_view_escape.d" \
        'scope|escape|local variable|lifetime|address'

    run_negative \
        "$compiler" \
        "$CASES/relation_foreach_view_escape.d" \
        'scope|escape|local variable|lifetime|address'
done

if (( failures != 0 )); then
    echo
    echo "DIP1000 negative-test failures: $failures"
    exit 1
fi

echo
echo 'DIP1000 negative tests: PASS'
