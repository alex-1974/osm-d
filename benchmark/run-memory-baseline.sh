#!/usr/bin/env bash
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/.." && pwd)"
cd "$repo"

compiler="${D_OSM_BENCH_COMPILER:-ldc2}"
passes="${D_OSM_MEMORY_PASSES:-3}"
datasets="${D_OSM_MEMORY_DATASETS:-bremen-260901 austria-260901}"
data_dir="${D_OSM_BENCH_DATA_DIR:-$repo/benchmark/data/geofabrik-2026-09-01}"
results_dir="${D_OSM_BENCH_RESULTS_DIR:-$repo/benchmark/results}"
run_id="${D_OSM_BENCH_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"

if ! [[ "$passes" =~ ^[2-9][0-9]*$|^[2-9]$ ]]; then
    echo "D_OSM_MEMORY_PASSES must be an integer >= 2." >&2
    exit 2
fi

command -v /usr/bin/time >/dev/null 2>&1 || {
    echo "/usr/bin/time is required for peak-RSS measurement." >&2
    exit 1
}

echo '=== BUILD ==='
(
    cd "$here"
    dub build \
        --config=parser-memory-baseline \
        --build=release \
        --build-mode=allAtOnce \
        --compiler="$compiler"
)

bin="$here/bin/osm-d-bench-memory-baseline"
mkdir -p "$results_dir"

manifest="$repo/benchmark/datasets/geofabrik-2026-09-01.tsv"

echo
echo '=== ENVIRONMENT ==='
"$compiler" --version | head -n 3
uname -sr
if command -v lscpu >/dev/null 2>&1; then
    lscpu | grep -E 'Model name|Socket|Core|Thread' || true
fi

for dataset_id in $datasets; do
    dataset_file="$(
        awk -F '\t' -v id="$dataset_id" '$1 == id {print $7; exit}' "$manifest"
    )"

    if [[ -z "$dataset_file" ]]; then
        echo "Unknown dataset ID: $dataset_id" >&2
        exit 2
    fi

    if ! OSM_D_BENCH_DATA="$data_dir"         "$repo/benchmark/fetch-datasets.sh" verify "$dataset_id"
    then
        OSM_D_BENCH_DATA="$data_dir"             "$repo/benchmark/fetch-datasets.sh" fetch "$dataset_id"
    fi

    data="$data_dir/$dataset_file"
    out="$results_dir/memory-baseline-${dataset_id}-${run_id}.txt"
    time_out="$results_dir/memory-baseline-${dataset_id}-${run_id}.time.txt"

    echo
    echo "=== DATASET: $dataset_id ==="
    /usr/bin/time -v -o "$time_out"         "$bin" --passes "$passes" "$data" | tee "$out"

    peak_kib="$(
        awk -F: '/Maximum resident set size/ {
            gsub(/^[[:space:]]+/, "", $2);
            print $2;
            exit
        }' "$time_out"
    )"

    printf 'peak_rss_kib=%s\n' "$peak_kib" | tee -a "$out"
    printf 'result=%s\n' "$out"
    printf 'time_detail=%s\n' "$time_out"
done
