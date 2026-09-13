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
            local row core sibling_rows
            row="$(lscpu -p=CPU,CORE,SOCKET 2>/dev/null | awk -F, -v c="$bench_cpu" '$1 == c {print; exit}')"
            if [[ -n "$row" ]]; then
                core="$(cut -d, -f2 <<< "$row")"
                sibling_rows="$(lscpu -p=CPU,CORE 2>/dev/null | awk -F, -v k="$core" '$2 == k {print $1}' | paste -sd, -)"
                printf 'physical core: %s  SMT logical CPUs: %s\n' "$core" "${sibling_rows:-unknown}"
            fi
        fi
    else
        echo 'CPU affinity: scheduler controlled (set D_OSM_BENCH_CPU=N for controlled runs)'
    fi

    printf 'compiler order: %s\n' "${compilers[*]}"
    printf 'pre-run cooldown: %ss\n' "$cooldown"
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
        --config=regular-ways \
        --build=release \
        --build-mode="$build_mode" \
        --compiler="$compiler"
}

run_benchmark() {
    local binary="$here/bin/d-osm-bench-regular-ways"

    if [[ "$cooldown" != "0" ]]; then
        sleep "$cooldown"
    fi

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
        print_thermal_snapshot
        run_benchmark "$@"
        print_thermal_snapshot
    fi
done

if [[ "$found" -eq 0 ]]; then
    echo "None of the requested compilers were found in PATH: ${compilers[*]}" >&2
    exit 1
fi
