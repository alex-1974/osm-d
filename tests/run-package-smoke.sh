#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/osm-d-package-smoke.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PKG="$TMP/package"
mkdir -p "$PKG"
git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$PKG"

required=(README.md LICENSE CHANGELOG.md dub.sdl source/osm/package.d docs/API_STABILITY.md docs/GETTING_STARTED.md)
for path in "${required[@]}"; do
  test -e "$PKG/$path" || { echo "missing release archive path: $path" >&2; exit 1; }
done

excluded=(.github benchmark tests examples tools .workspace AGENTS.md)
for path in "${excluded[@]}"; do
  test ! -e "$PKG/$path" || { echo "unexpected release archive path: $path" >&2; exit 1; }
done

read -r -a compilers <<< "${PACKAGE_SMOKE_COMPILERS:-dmd ldc2}"
for compiler in "${compilers[@]}"; do
  command -v "$compiler" >/dev/null 2>&1 || {
    echo "required compiler not found: $compiler" >&2
    exit 2
  }

  echo "=== PACKAGE BUILD: $compiler ==="
  dub build --root="$PKG" --compiler="$compiler" --build=release --force

  CONSUMER="$TMP/consumer-$(basename "$compiler")"
  mkdir -p "$CONSUMER/source"
  cat >"$CONSUMER/dub.sdl" <<EOF
name "osm-d-archive-consumer"
description "clean consumer for archived osm-d"
authors "osm-d CI"
license "MIT"
targetType "executable"
sourcePaths "source"

dependency "osm-d" path="$PKG"
EOF
  cat >"$CONSUMER/source/app.d" <<'EOF'
module app;
import osm;

@safe void main()
{
    auto store = new OsmStore();
    OwnedNode node;
    node.id = 1;
    node.location = LocationView(1, 2);
    OsmHandle handle;
    StoreStatus status;
    assert(store.add(node, handle, status));
    OsmHandle found;
    assert(store.find(ElementType.node, 1, found));
    assert(found == handle);
}
EOF

  echo "=== ARCHIVE CONSUMER: $compiler ==="
  dub build --root="$CONSUMER" --compiler="$compiler" --build=debug --force
done

echo "PASS: consumer archive shape and clean external build"
