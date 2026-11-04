#!/usr/bin/env bash
set -euo pipefail

compiler="${1:?usage: setup-dmd-ci.sh dmd-X.Y.Z [dub-version]}"
dub_version="${2:-1.40.0}"

case "$compiler" in
  dmd-*) ;;
  *)
    echo "fallback is only for an exact DMD compiler request: $compiler" >&2
    exit 2
    ;;
esac

root="${RUNNER_TEMP:-/tmp}/osm-d-dlang"
mkdir -p "$root"

installer="$root/install.sh"
curl --fail --show-error --silent --location   https://dlang.org/install.sh   -o "$installer"
chmod +x "$installer"

toolchains="$root/toolchains"
"$installer" -p "$toolchains" install "$compiler,dub-$dub_version"

dc="$("$installer" -p "$toolchains" get-path --dmd "$compiler")"
dub="$("$installer" -p "$toolchains" get-path --dub "dub-$dub_version")"

"$dc" --version
"$dub" --version

{
  echo "DC=$dc"
  echo "DMD=$dc"
} >>"$GITHUB_ENV"

{
  dirname "$dc"
  dirname "$dub"
} >>"$GITHUB_PATH"
