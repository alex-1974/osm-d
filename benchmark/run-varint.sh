#!/usr/bin/env bash
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

build_mode="${D_OSM_BENCH_BUILD_MODE:-allAtOnce}"
bench_cpu="${D_OSM_BENCH_CPU:-}"
show_sensors="${D_OSM_BENCH_SENSORS:-0}"
cooldown="${D_OSM_BENCH_COOLDOWN:-0}"
read -r -a compilers <<< "${D_OSM_BENCH_COMPILERS:-dmd ldc2}"

print_environment() {
    printf 'build mode: %s\n' "$build_mode"

    if command -v lscpu >/dev/null 2>&1; then
        local model
        model="$(lscpu | awk -F: '/Model name:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}')"
        if [[ -n "$model" ]]; then
            printf 'CPU: %s\n' "$model"
        fi
        printf 'logical CPUs: %s\n' "$(nproc)"
    fi

    if [[ -n "$bench_cpu" ]]; then
        if ! command -v taskset >/dev/null 2>&1; then
            echo "D_OSM_BENCH_CPU is set but taskset is not available." >&2
            exit 1
        fi
        printf 'CPU affinity: %s\n' "$bench_cpu"

        if command -v lscpu >/dev/null 2>&1; then
            local core siblings
            core="$(lscpu -p=CPU,CORE 2>/dev/null \
                | awk -F, -v cpu="$bench_cpu" '$1 !~ /^#/ && $1 == cpu {print $2; exit}')"
            if [[ -n "$core" ]]; then
                siblings="$(lscpu -p=CPU,CORE 2>/dev/null \
                    | awk -F, -v core="$core" '$1 !~ /^#/ && $2 == core {printf "%s%s", sep, $1; sep=","}')"
                printf 'physical core: %s  logical siblings: %s\n' "$core" "$siblings"
            fi
        fi
    else
        echo 'CPU affinity: scheduler controlled (set D_OSM_BENCH_CPU=N for controlled runs)'
    fi

    printf 'compiler order: %s\n' "${compilers[*]}"
    printf 'post-build cooldown: %ss\n' "$cooldown"
}

print_thermal_snapshot() {
    if [[ "$show_sensors" == "1" ]] && command -v sensors >/dev/null 2>&1; then
        echo 'thermal snapshot:'
        sensors 2>/dev/null \
            | grep -E 'Package id [0-9]+:|Tctl:|Tdie:|Core [0-9]+:' \
            | head -n 24 \
            || true
    fi
}

build_benchmark() {
    local compiler="$1"
    dub build \
        --config=varint \
        --build=release \
        --build-mode="$build_mode" \
        --compiler="$compiler"
}

cool_down_after_build() {
    if [[ "$cooldown" != "0" ]]; then
        printf 'cooling down after build: %ss\n' "$cooldown"
        sleep "$cooldown"
    fi
}

run_benchmark() {
    local binary="$here/bin/osm-d-bench-varint"

    if [[ -n "$bench_cpu" ]]; then
        taskset -c "$bench_cpu" "$binary" "$@"
    else
        "$binary" "$@"
    fi
}

print_environment

found=0
for compiler in "${compilers[@]}"; do
    if command -v "$compiler" >/dev/null 2>&1; then
        found=1
        printf '\n=== %s ===\n' "$compiler"
        "$compiler" --version | head -n 2
        build_benchmark "$compiler"
        cool_down_after_build
        echo 'pre-benchmark state:'
        print_thermal_snapshot
        run_benchmark "$@"
        echo 'post-benchmark state:'
        print_thermal_snapshot
    fi
done

if [[ "$found" -eq 0 ]]; then
    echo "None of the requested compilers were found in PATH: ${compilers[*]}" >&2
    exit 1
fi
