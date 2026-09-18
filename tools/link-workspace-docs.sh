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

files=(
    README.md
    ROADMAP.md
    DESIGN_PRINCIPLES.md
    RESEARCH.md
)

for file in "${files[@]}"; do
    if [[ ! -f "$workspace_root/$file" ]]; then
        echo "missing workspace document: $workspace_root/$file" >&2
        exit 1
    fi
done

if ! git -C "$repo_root" check-ignore -q .workspace/README.md; then
    echo "ERROR: .workspace/ is not ignored by this repository" >&2
    exit 1
fi

mkdir -p "$workspace_dir"

for file in "${files[@]}"; do
    source="$workspace_root/$file"
    target="$workspace_dir/$file"

    if [[ -e "$target" ]]; then
        source_inode="$(stat -c '%d:%i' "$source")"
        target_inode="$(stat -c '%d:%i' "$target")"

        if [[ "$source_inode" == "$target_inode" ]]; then
            echo "OK   .workspace/$file"
            continue
        fi

        echo "ERROR: $target exists but is not the workspace hardlink" >&2
        echo "       refusing to overwrite it" >&2
        exit 1
    fi

    ln "$source" "$target"
    echo "LINK .workspace/$file"
done
