#!/usr/bin/env bash
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/.." && pwd)"
cd "$repo"

build_mode="${D_OSM_BENCH_BUILD_MODE:-allAtOnce}"
bench_cpu="${D_OSM_BENCH_CPU:-}"
show_sensors="${D_OSM_BENCH_SENSORS:-0}"
cooldown="${D_OSM_BENCH_COOLDOWN:-0}"
dataset_id="${D_OSM_BENCH_DATASET:-bremen-260901}"
blocks="${D_OSM_BENCH_BLOCKS:-5}"
d_compiler="${D_OSM_BENCH_COMPILER:-ldc2}"
cxx="${D_OSM_BENCH_CXX:-clang++}"

manifest="$repo/benchmark/datasets/geofabrik-2026-09-01.tsv"
data_dir="${D_OSM_BENCH_DATA_DIR:-$repo/benchmark/data/geofabrik-2026-09-01}"

if ! [[ "$blocks" =~ ^[1-9][0-9]*$ ]]; then
    echo "D_OSM_BENCH_BLOCKS must be a positive integer." >&2
    exit 2
fi

dataset_file="$(
    awk -F '\t' -v id="$dataset_id" '$1 == id {print $7; exit}' "$manifest"
)"

if [[ -z "$dataset_file" ]]; then
    echo "Unknown dataset ID: $dataset_id" >&2
    exit 2
fi

data="$data_dir/$dataset_file"
d_bin="$here/bin/osm-d-bench-decode-count"
o_bin="$here/bin/libosmium-decode-count"

results_dir="${D_OSM_BENCH_RESULTS_DIR:-$repo/benchmark/results}"
run_id="${D_OSM_BENCH_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
csv="$results_dir/parser-decode-count-${dataset_id}-${run_id}.csv"

print_environment() {
    printf 'dataset: %s\n' "$dataset_id"
    printf 'dataset path: %s\n' "$data"
    printf 'build mode: %s\n' "$build_mode"
    printf 'D compiler: %s\n' "$d_compiler"
    printf 'C++ compiler: %s\n' "$cxx"
    printf 'balanced blocks: %s\n' "$blocks"

    if command -v uname >/dev/null 2>&1; then
        printf 'kernel: '
        uname -sr
    fi

    if command -v lscpu >/dev/null 2>&1; then
        local model
        model="$(
            lscpu |
            awk -F: '/Model name:/ {
                sub(/^[[:space:]]+/, "", $2);
                print $2;
                exit
            }'
        )"
        [[ -z "$model" ]] || printf 'CPU: %s\n' "$model"
        printf 'logical CPUs: %s\n' "$(nproc)"
    fi

    if [[ -n "$bench_cpu" ]]; then
        if ! command -v taskset >/dev/null 2>&1; then
            echo "D_OSM_BENCH_CPU is set but taskset is unavailable." >&2
            exit 1
        fi

        printf 'CPU affinity: %s\n' "$bench_cpu"

        if command -v lscpu >/dev/null 2>&1; then
            local row core siblings
            row="$(
                lscpu -p=CPU,CORE,SOCKET 2>/dev/null |
                awk -F, -v c="$bench_cpu" '$1 == c {print; exit}'
            )"
            if [[ -n "$row" ]]; then
                core="$(cut -d, -f2 <<< "$row")"
                siblings="$(
                    lscpu -p=CPU,CORE 2>/dev/null |
                    awk -F, -v k="$core" \
                        '$1 !~ /^#/ && $2 == k {print $1}' |
                    paste -sd, -
                )"
                printf 'physical core: %s  SMT logical CPUs: %s\n' \
                    "$core" "${siblings:-unknown}"
            fi
        fi
    else
        echo 'CPU affinity: scheduler controlled (set D_OSM_BENCH_CPU=N for controlled runs)'
    fi

    printf 'post-build cooldown: %ss\n' "$cooldown"
}

print_thermal_snapshot() {
    if [[ "$show_sensors" == "1" ]] &&
       command -v sensors >/dev/null 2>&1
    then
        echo 'thermal snapshot:'
        sensors 2>/dev/null |
            grep -E 'Package id [0-9]+:|Tctl:|Tdie:|Core [0-9]+:' |
            head -n 24 ||
            true
    fi
}

run_pinned() {
    if [[ -n "$bench_cpu" ]]; then
        taskset -c "$bench_cpu" "$@"
    else
        "$@"
    fi
}

extract_counts() {
    grep -E \
        '^(bytes|header_blocks|data_blocks|nodes|ways|relations|tags)='
}

elapsed_ns() {
    awk -F= '/^elapsed_ns=/ {print $2; exit}'
}

echo '=== ENVIRONMENT ==='
print_environment

echo
echo '=== TOOLCHAINS ==='
"$d_compiler" --version | head -n 3
echo
"$cxx" --version | head -n 2

echo
echo '=== VERIFY DATASET ==='
"$repo/benchmark/fetch-datasets.sh" verify "$dataset_id"
printf 'bytes: '
stat -c '%s' "$data"
printf 'sha256: '
sha256sum "$data" | awk '{print $1}'

echo
echo '=== BUILD osm-d ==='
(
    cd "$here"
    dub build \
        --config=parser-decode-count \
        --build=release \
        --build-mode="$build_mode" \
        --compiler="$d_compiler"
)

echo
echo '=== BUILD libosmium REFERENCE ==='
mkdir -p "$here/bin"
"$cxx" \
    -std=c++17 \
    -O3 \
    -DNDEBUG \
    -pthread \
    "$here/reference/libosmium_decode_count.cpp" \
    -o "$o_bin" \
    -lz -lexpat -lbz2 -llz4

if [[ "$cooldown" != "0" ]]; then
    echo
    printf 'cooling down after build: %ss\n' "$cooldown"
    sleep "$cooldown"
fi

echo
echo '=== PRE-RUN STATE ==='
print_thermal_snapshot

echo
echo '=== SEMANTIC PARITY ==='
d_counts="$(run_pinned "$d_bin" "$data" | extract_counts)"
o_counts="$(run_pinned "$o_bin" "$data" | extract_counts)"

printf '%s\n' "$d_counts" > /tmp/osm-d-decode-count-d.txt
printf '%s\n' "$o_counts" > /tmp/osm-d-decode-count-o.txt

if diff -u \
    /tmp/osm-d-decode-count-d.txt \
    /tmp/osm-d-decode-count-o.txt
then
    echo 'PARITY PASS'
else
    echo 'PARITY FAIL' >&2
    exit 1
fi

printf '%s\n' "$d_counts"

echo
echo '=== PRIME BOTH IMPLEMENTATIONS ==='
run_pinned "$d_bin" --measure "$data" >/dev/null
run_pinned "$o_bin" --measure "$data" >/dev/null

d_samples="$(mktemp)"
o_samples="$(mktemp)"
trap 'rm -f "$d_samples" "$o_samples"' EXIT

mkdir -p "$results_dir"
printf '%s\n' \
    'dataset_id,block,position,order,implementation,elapsed_ns' \
    > "$csv"

run_d() {
    local block="$1"
    local position="$2"
    local order="$3"
    local ns

    ns="$(
        run_pinned "$d_bin" --measure "$data" |
        elapsed_ns
    )"

    printf '%s\n' "$ns" >> "$d_samples"
    printf '%s,%s,%s,%s,%s,%s\n' \
        "$dataset_id" "$block" "$position" "$order" "osm-d" "$ns" \
        >> "$csv"
    printf '%s\n' "$ns"
}

run_o() {
    local block="$1"
    local position="$2"
    local order="$3"
    local ns

    ns="$(
        run_pinned "$o_bin" --measure "$data" |
        elapsed_ns
    )"

    printf '%s\n' "$ns" >> "$o_samples"
    printf '%s,%s,%s,%s,%s,%s\n' \
        "$dataset_id" "$block" "$position" "$order" "libosmium" "$ns" \
        >> "$csv"
    printf '%s\n' "$ns"
}

echo
echo "=== BALANCED SERIES: $blocks BLOCKS ==="
for ((block = 1; block <= blocks; ++block)); do
    echo "--- block $block ---"

    if (( block % 2 == 1 )); then
        order='DOOD'
        printf 'D  '; run_d "$block" 1 "$order"
        printf 'O  '; run_o "$block" 2 "$order"
        printf 'O  '; run_o "$block" 3 "$order"
        printf 'D  '; run_d "$block" 4 "$order"
    else
        order='ODDO'
        printf 'O  '; run_o "$block" 1 "$order"
        printf 'D  '; run_d "$block" 2 "$order"
        printf 'D  '; run_d "$block" 3 "$order"
        printf 'O  '; run_o "$block" 4 "$order"
    fi

    print_thermal_snapshot
done

echo
echo '=== DESCRIPTIVE SUMMARY ==='
python3 - "$d_samples" "$o_samples" <<'PY'
import sys

def load(path):
    with open(path) as f:
        return [int(line.strip()) / 1e6 for line in f if line.strip()]

def percentile(values, fraction):
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]

    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight

def describe(name, values):
    p10 = percentile(values, 0.10)
    p50 = percentile(values, 0.50)
    p90 = percentile(values, 0.90)
    delta80 = (p90 - p10) / p50 * 100.0 if p50 else float("nan")

    print(
        f"{name} n={len(values)} "
        f"min={min(values):.3f} "
        f"p10={p10:.3f} "
        f"p50={p50:.3f} "
        f"p90={p90:.3f} "
        f"max={max(values):.3f} ms "
        f"delta80={delta80:.1f}%"
    )
    return p50

d = load(sys.argv[1])
o = load(sys.argv[2])

if not d or not o:
    raise SystemExit("no timing samples collected")

print("osm-d samples_ms:")
print(" ".join(f"{x:.3f}" for x in d))
print("libosmium samples_ms:")
print(" ".join(f"{x:.3f}" for x in o))
print()

dmed = describe("osm-d", d)
omed = describe("libosmium", o)

print(f"median ratio osm-d/libosmium={dmed / omed:.3f}")
print(f"osm-d relative throughput={omed / dmed * 100.0:.1f}%")
print()
print(
    "NOTE: this summary is descriptive. Frequency/thermal instability "
    "must be assessed before publishing a throughput claim."
)
PY

echo
printf 'raw CSV: %s\n' "$csv"

echo
echo '=== POST-RUN STATE ==='
print_thermal_snapshot
