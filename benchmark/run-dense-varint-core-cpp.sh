#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
bench_cpu="${D_OSM_BENCH_CPU:-}"
show_sensors="${D_OSM_BENCH_SENSORS:-0}"
cooldown="${D_OSM_BENCH_COOLDOWN:-0}"
read -r -a compilers <<< "${D_OSM_CPP_COMPILERS:-clang++ g++}"
extra_flags="${D_OSM_CPP_FLAGS:-}"

thermal() {
    if [[ "$show_sensors" == "1" ]] && command -v sensors >/dev/null 2>&1; then
        sensors 2>/dev/null | grep -E 'Package id [0-9]+:|Core [0-9]+:' | head -n 24 || true
    fi
}

mkdir -p "$here/bin"
printf 'logical CPUs: %s\n' "$(nproc)"
[[ -n "$bench_cpu" ]] && printf 'CPU affinity: %s\n' "$bench_cpu" || echo 'CPU affinity: scheduler controlled'
printf 'C++ compiler order: %s\n' "${compilers[*]}"
printf 'C++ flags: -std=c++20 -O3 -DNDEBUG%s\n' "${extra_flags:+ $extra_flags}"
printf 'pre-run cooldown: %ss\n' "$cooldown"

found=0
for compiler in "${compilers[@]}"; do
    if command -v "$compiler" >/dev/null 2>&1; then
        found=1
        printf '\n=== %s ===\n' "$compiler"
        "$compiler" --version | head -n 2
        tag="$(basename "$compiler" | tr -c 'A-Za-z0-9_.-' '_')"
        binary="$here/bin/osm-d-bench-dense-varint-core-cpp-$tag"
        flags=(-std=c++20 -O3 -DNDEBUG)
        if [[ -n "$extra_flags" ]]; then
            # shellcheck disable=SC2206
            more=($extra_flags)
            flags+=("${more[@]}")
        fi
        "$compiler" "${flags[@]}" "$here/reference/dense_varint_core_cpp.cpp" -o "$binary"
        [[ "$cooldown" != "0" ]] && sleep "$cooldown"
        thermal
        if [[ -n "$bench_cpu" ]]; then
            taskset -c "$bench_cpu" "$binary" "$@"
        else
            "$binary" "$@"
        fi
        thermal
    fi
done
[[ "$found" -eq 1 ]] || { echo "No requested C++ compiler found" >&2; exit 1; }
