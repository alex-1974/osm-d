#!/usr/bin/env bash
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/.." && pwd)"
cd "$repo"

compiler="${D_OSM_BENCH_COMPILER:-ldc2}"
dataset_id="${D_OSM_SCALING_DATASET:-bremen-260901}"
samples="${D_OSM_SCALING_SAMPLES:-5}"
max_workers="${D_OSM_SCALING_MAX_WORKERS:-8}"
queue_factor="${D_OSM_SCALING_QUEUE_FACTOR:-2}"
data_dir="${D_OSM_BENCH_DATA_DIR:-$repo/benchmark/data/geofabrik-2026-09-01}"
results_dir="${D_OSM_BENCH_RESULTS_DIR:-$repo/benchmark/results}"
run_id="${D_OSM_BENCH_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"

for value in "$samples" "$max_workers" "$queue_factor"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        echo "scaling controls must be positive integers" >&2
        exit 2
    }
done

manifest="$repo/benchmark/datasets/geofabrik-2026-09-01.tsv"
dataset_file="$(
    awk -F '\t' -v id="$dataset_id" '$1 == id {print $7; exit}' "$manifest"
)"
[[ -n "$dataset_file" ]] || {
    echo "unknown dataset: $dataset_id" >&2
    exit 2
}

if ! OSM_D_BENCH_DATA="$data_dir"     "$repo/benchmark/fetch-datasets.sh" verify "$dataset_id"
then
    OSM_D_BENCH_DATA="$data_dir"         "$repo/benchmark/fetch-datasets.sh" fetch "$dataset_id"
fi

data="$data_dir/$dataset_file"

echo '=== BUILD ==='
(
    cd "$here"
    dub build \
        --config=parser-parallel-summary \
        --build=release \
        --build-mode=allAtOnce \
        --compiler="$compiler"
)

bin="$here/bin/osm-d-bench-parallel-summary"
mkdir -p "$results_dir"
csv="$results_dir/parallel-summary-${dataset_id}-${run_id}.csv"
echo 'dataset,workers,queue_capacity,sample,elapsed_ns,peak_rss_kib' > "$csv"

logical_cpus="$(nproc)"
limit="$max_workers"
if (( logical_cpus < limit )); then
    limit="$logical_cpus"
fi

workers=(1)
candidate=2
while (( candidate <= limit )); do
    workers+=("$candidate")
    candidate=$((candidate * 2))
done
if (( limit > 1 && workers[${#workers[@]}-1] != limit )); then
    workers+=("$limit")
fi

extract_counts() {
    grep -E '^(bytes|header_blocks|data_blocks|primitive_groups|nodes|ways|relations|tags)='
}

elapsed_ns() {
    awk -F= '/^elapsed_ns=/ {print $2; exit}'
}

echo
echo '=== ENVIRONMENT ==='
"$compiler" --version | head -n 3
uname -sr
printf 'logical_cpus=%s\n' "$logical_cpus"
printf 'worker_series=%s\n' "${workers[*]}"
printf 'queue_factor=%s\n' "$queue_factor"
if command -v lscpu >/dev/null 2>&1; then
    lscpu | grep -E 'Model name|Socket|Core|Thread' || true
fi

echo
echo '=== SEMANTIC PARITY ==='
serial_counts="$("$bin" serial "$data" | extract_counts)"
printf '%s\n' "$serial_counts"

for w in "${workers[@]}"; do
    q=$((w * queue_factor))
    parallel_counts="$("$bin" parallel "$w" "$q" "$data" | extract_counts)"
    diff -u <(printf '%s\n' "$serial_counts") <(printf '%s\n' "$parallel_counts")
    echo "PASS workers=$w queue=$q"
done

echo
echo '=== TIMING / PEAK RSS ==='
for w in 0 "${workers[@]}"; do
    if (( w == 0 )); then
        mode=(serial)
        q=0
        label=serial
    else
        q=$((w * queue_factor))
        mode=(parallel "$w" "$q")
        label="workers=$w"
    fi

    for ((sample=1; sample<=samples; ++sample)); do
        tmp_time="$(mktemp)"
        output="$(
            /usr/bin/time -v -o "$tmp_time"                 "$bin" --measure "${mode[@]}" "$data"
        )"
        ns="$(printf '%s\n' "$output" | elapsed_ns)"
        peak="$(
            awk -F: '/Maximum resident set size/ {
                gsub(/^[[:space:]]+/, "", $2);
                print $2;
                exit
            }' "$tmp_time"
        )"
        rm -f "$tmp_time"

        printf '%s sample=%s elapsed_ns=%s peak_rss_kib=%s\n'             "$label" "$sample" "$ns" "$peak"
        echo "$dataset_id,$w,$q,$sample,$ns,$peak" >> "$csv"
    done
done

echo
echo '=== SUMMARY ==='
python3 - "$csv" <<'PY'
import csv
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1], newline="")))
groups = {}
for row in rows:
    key = int(row["workers"])
    groups.setdefault(key, []).append(row)

serial_ms = statistics.median(
    int(r["elapsed_ns"]) / 1e6 for r in groups[0]
)
serial_rss = statistics.median(
    int(r["peak_rss_kib"]) for r in groups[0]
)

print(
    f"serial p50={serial_ms:.3f} ms "
    f"peak_rss_p50={serial_rss:.0f} KiB"
)

one_ms = None
for workers in sorted(k for k in groups if k != 0):
    rows_for_group = groups[workers]
    ms = statistics.median(
        int(r["elapsed_ns"]) / 1e6 for r in rows_for_group
    )
    rss = statistics.median(
        int(r["peak_rss_kib"]) for r in rows_for_group
    )
    if workers == 1:
        one_ms = ms

    versus_serial = serial_ms / ms
    versus_one = (one_ms / ms) if one_ms else float("nan")

    print(
        f"workers={workers:2d} "
        f"p50={ms:9.3f} ms "
        f"speedup_vs_serial={versus_serial:5.2f}x "
        f"speedup_vs_1worker={versus_one:5.2f}x "
        f"peak_rss_p50={rss:.0f} KiB"
    )
PY

echo
echo "raw CSV: $csv"
