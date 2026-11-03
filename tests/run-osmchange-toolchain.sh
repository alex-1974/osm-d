#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPILER="${OSMCHANGE_COMPILER:-dmd}"
OUT="$(mktemp /tmp/osm-d-osmchange.XXXXXX.osc)"
trap 'rm -f "$OUT"' EXIT

command -v osmium >/dev/null 2>&1 || {
    echo "required external tool not found: osmium" >&2
    exit 2
}

dub run \
    --root="$ROOT/tests/osmchange-toolchain" \
    --compiler="$COMPILER" \
    --build=debug \
    --force \
    > "$OUT"

# Parsing the library-produced .osc with libosmium/osmium-tool is the
# independent syntax/interoperability gate. No byte-identical output is assumed.
osmium fileinfo "$OUT" >/dev/null

echo "PASS: osmChange output accepted by osmium-tool"
