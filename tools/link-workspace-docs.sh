#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="${1:-}"

if [[ -z "$workspace_root" ]]; then
    echo "usage: $0 /path/to/d-geospatial-workspace" >&2
    exit 2
fi

workspace_root="$(cd "$workspace_root" && pwd)"
workspace_dir="$repo_root/.workspace"

files=(README.md ROADMAP.md DESIGN_PRINCIPLES.md)

for file in "${files[@]}"; do
    if [[ ! -f "$workspace_root/$file" ]]; then
        echo "missing workspace document: $workspace_root/$file" >&2
        exit 1
    fi
done

# This helper is intentionally restricted to .workspace/.
rm -rf -- "$workspace_dir"
mkdir -p -- "$workspace_dir"

for file in "${files[@]}"; do
    ln -- "$workspace_root/$file" "$workspace_dir/$file"
done

printf 'linked workspace documents into %s\n' "$workspace_dir"
