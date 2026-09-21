#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="$ROOT/benchmark/datasets/geofabrik-2026-09-01.tsv"
DATA_DIR="${OSM_D_BENCH_DATA:-$ROOT/benchmark/data/geofabrik-2026-09-01}"

usage() {
    cat <<'USAGE'
Usage:
  benchmark/fetch-datasets.sh verify [dataset-id ...]
  benchmark/fetch-datasets.sh fetch  [dataset-id ...]

With no dataset IDs, all datasets in the pinned manifest are selected.

The large PBF files are stored under benchmark/data/ by default and are
intentionally excluded from Git.
USAGE
}

mode=${1:-}
case "$mode" in
    verify|fetch) shift ;;
    *) usage >&2; exit 2 ;;
esac

wanted=("$@")

# Reject every unknown explicitly requested ID before doing any work.
# A mixed request such as "monaco-260901 typo" must fail closed rather
# than silently processing only the known subset.
if ((${#wanted[@]} > 0)); then
    for candidate in "${wanted[@]}"; do
        if ! awk -F '\t' -v id="$candidate" \
            'NR > 1 && $1 == id { found = 1 } END { exit found ? 0 : 1 }' \
            "$MANIFEST"
        then
            echo "unknown dataset ID: $candidate" >&2
            exit 2
        fi
    done
fi

selected() {
    local id=$1
    if ((${#wanted[@]} == 0)); then
        return 0
    fi

    local candidate
    for candidate in "${wanted[@]}"; do
        [[ "$candidate" == "$id" ]] && return 0
    done
    return 1
}

verify_file() {
    local path=$1 expected_size=$2 expected_sha256=$3 expected_md5=$4

    [[ -f "$path" ]] || {
        echo "missing: $path" >&2
        return 1
    }

    local actual_size actual_sha256 actual_md5
    actual_size=$(stat --printf='%s' "$path")
    actual_sha256=$(sha256sum "$path" | awk '{print $1}')
    actual_md5=$(md5sum "$path" | awk '{print $1}')

    [[ "$actual_size" == "$expected_size" ]] || {
        echo "size mismatch: $path" >&2
        echo "  expected: $expected_size" >&2
        echo "  actual:   $actual_size" >&2
        return 1
    }

    [[ "$actual_sha256" == "$expected_sha256" ]] || {
        echo "SHA-256 mismatch: $path" >&2
        return 1
    }

    [[ "$actual_md5" == "$expected_md5" ]] || {
        echo "MD5 mismatch: $path" >&2
        return 1
    }

    echo "OK  $(basename "$path")"
}

mkdir -p "$DATA_DIR"

count=0
while IFS=$'\t' read -r \
    id class purpose provider snapshot_date verified_date filename size_bytes sha256 md5 url
do
    [[ "$id" == "id" ]] && continue
    selected "$id" || continue
    ((++count))

    path="$DATA_DIR/$filename"

    if [[ "$mode" == "fetch" ]]; then
        if verify_file "$path" "$size_bytes" "$sha256" "$md5" >/dev/null 2>&1; then
            echo "SKIP $filename (already verified)"
        else
            part="$path.part"
            echo "FETCH $id"
            curl -fL --retry 3 --continue-at - -o "$part" "$url"
            verify_file "$part" "$size_bytes" "$sha256" "$md5"
            mv "$part" "$path"
        fi
    else
        verify_file "$path" "$size_bytes" "$sha256" "$md5"
    fi
done < "$MANIFEST"

if ((count == 0)); then
    echo "no matching dataset IDs" >&2
    exit 2
fi
