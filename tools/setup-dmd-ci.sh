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

# Pin the fallback bootstrap itself to immutable official D-Language commits.
# The downloaded DMD release archive is still verified by the official D
# keyring. Rewriting the Digital Mars mirror to HTTPS avoids plain-HTTP
# transport when downloads.dlang.org is unavailable.
installer_commit="6e8bf6c245120c3d39c1f929f133e284e49d017d"
dlang_org_commit="a7adf6055c0e579018d27a96a474d826b795a398"

root="${RUNNER_TEMP:-/tmp}/osm-d-dlang"
toolchains="$root/toolchains"
mkdir -p "$toolchains"

curl_retry=(
  --fail
  --show-error
  --silent
  --location
  --retry 5
  --retry-delay 2
  --retry-all-errors
)

installer="$toolchains/install.sh"
keyring="$toolchains/d-keyring.gpg"

curl "${curl_retry[@]}"   "https://raw.githubusercontent.com/dlang/installer/$installer_commit/script/install.sh"   -o "$installer"
curl "${curl_retry[@]}"   "https://raw.githubusercontent.com/dlang/dlang.org/$dlang_org_commit/d-keyring.gpg"   -o "$keyring"

chmod +x "$installer"

# The official installer currently lists Digital Mars as an HTTP fallback.
# The same mirror is available over HTTPS; keep the fallback encrypted.
sed -i   's#http://ftp\.digitalmars\.com/#https://ftp.digitalmars.com/#g'   "$installer"

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
