#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
build_mode="${D_OSM_BENCH_BUILD_MODE:-allAtOnce}"
bench_cpu="${D_OSM_BENCH_CPU:-}"
show_sensors="${D_OSM_BENCH_SENSORS:-0}"
cooldown="${D_OSM_BENCH_COOLDOWN:-0}"
read -r -a compilers <<< "${D_OSM_BENCH_COMPILERS:-ldc2}"

thermal() {
    if [[ "$show_sensors" == "1" ]] && command -v sensors >/dev/null 2>&1; then
        sensors 2>/dev/null | grep -E 'Package id [0-9]+:|Core [0-9]+:' | head -n 24 || true
    fi
}

printf 'logical CPUs: %s\n' "$(nproc)"
[[ -n "$bench_cpu" ]] && printf 'CPU affinity: %s\n' "$bench_cpu" || echo 'CPU affinity: scheduler controlled'
printf 'compiler order: %s\n' "${compilers[*]}"
printf 'pre-run cooldown: %ss\n' "$cooldown"

found=0
for compiler in "${compilers[@]}"; do
    if command -v "$compiler" >/dev/null 2>&1; then
        found=1
        printf '\n=== %s ===\n' "$compiler"
        "$compiler" --version | head -n 2
        dub build --config=dense-coordinate-stages --build=release --build-mode="$build_mode" --compiler="$compiler" --force
        [[ "$cooldown" != "0" ]] && sleep "$cooldown"
        thermal
        if [[ -n "$bench_cpu" ]]; then
            taskset -c "$bench_cpu" "$here/bin/osm-d-bench-dense-coordinate-stages" "$@"
        else
            "$here/bin/osm-d-bench-dense-coordinate-stages" "$@"
        fi
        thermal
    fi
done
[[ "$found" -eq 1 ]] || { echo "No requested D compiler found" >&2; exit 1; }
