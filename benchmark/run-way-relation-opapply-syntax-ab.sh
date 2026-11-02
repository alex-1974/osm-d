#!/usr/bin/env bash
set -euo pipefail

ROOT="${OSM_D_ROOT:-$HOME/Programmiersprachen/dlang/d-geospatial-workspace/libs/osm-d}"
BRANCH="feat/pbf-way-relation-foreach"
CAND="e6726cab74b089a709b9911fdad0910c698d8101"
DATASET_ID="${D_OSM_BENCH_DATASET:-bremen-260901}"
CPU="${D_OSM_BENCH_CPU:-5}"
BLOCKS="${D_OSM_BENCH_BLOCKS:-6}"
COOLDOWN="${D_OSM_BENCH_COOLDOWN:-20}"
GAP="${D_OSM_BENCH_GAP:-1}"
COMPILER="${D_OSM_BENCH_COMPILER:-ldc-1.41.0}"
DUB="${D_OSM_BENCH_DUB:-dub-dlang-baseline}"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -d "$ROOT/.git" ]] || fail "repository not found: $ROOT"
command -v "$COMPILER" >/dev/null 2>&1 || fail "compiler not found: $COMPILER"
command -v "$DUB" >/dev/null 2>&1 || fail "DUB not found: $DUB"
command -v taskset >/dev/null 2>&1 || fail "taskset not found"

cd "$ROOT"
echo '=== FETCH / VERIFY ==='
git fetch origin develop "$BRANCH"
REMOTE="$(git rev-parse "origin/$BRANCH")"
echo "branch head: $REMOTE"
echo "candidate:   $CAND"
git merge-base --is-ancestor "$CAND" "origin/$BRANCH" ||
    fail "candidate $CAND is not an ancestor of origin/$BRANCH"

WT="$(mktemp -d /tmp/osm-d-opapply-syntax-wt.XXXXXX)"
TMP="$(mktemp -d /tmp/osm-d-opapply-syntax-src.XXXXXX)"
cleanup() {
    git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true
    rm -rf "$WT" "$TMP" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git worktree add --detach "$WT" "$CAND"

DATA_DIR="${D_OSM_BENCH_DATA_DIR:-$ROOT/benchmark/data/geofabrik-2026-09-01}"
if ! OSM_D_BENCH_DATA="$DATA_DIR" "$WT/benchmark/fetch-datasets.sh" verify "$DATASET_ID"; then
    OSM_D_BENCH_DATA="$DATA_DIR" "$WT/benchmark/fetch-datasets.sh" fetch "$DATASET_ID"
fi
MANIFEST="$WT/benchmark/datasets/geofabrik-2026-09-01.tsv"
DATASET_FILE="$(awk -F '\t' -v id="$DATASET_ID" '$1 == id {print $7; exit}' "$MANIFEST")"
[[ -n "$DATASET_FILE" ]] || fail "dataset not found in manifest: $DATASET_ID"
DATA="$DATA_DIR/$DATASET_FILE"

cat > "$TMP/dub.sdl" <<EOF
name "osm-d-opapply-syntax-ab"
description "Temporary foreach syntax vs explicit opApply diagnostic"
authors "OpenAI qualification helper"
license "MIT"
dependency "osm-d" path="$WT"
targetType "executable"
targetName "opapply-syntax-ab"
targetPath "bin"
sourcePaths "source"
mainSourceFile "source/app.d"
EOF

mkdir -p "$TMP/source"
cat > "$TMP/source/app.d" <<'D'
module app;

import osm :
    MetadataView,
    PbfReader,
    RelationView,
    WayView;

import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : stderr, writefln;

private enum Mode
{
    way,
    relation,
}

private struct Result
{
    ulong checksum;
    size_t elements;
    size_t metadataElements;
}

pragma(inline, true)
private ulong mix(ulong state, ulong value) @safe pure nothrow @nogc
{
    return state ^
        (value + 0x9e37_79b9_7f4a_7c15UL + (state << 6) + (state >> 2));
}

pragma(inline, true)
private void consumeMetadata(
    MetadataView metadata,
    ref Result result)
    @safe nothrow @nogc
{
    const present =
        metadata.hasVersion ||
        metadata.hasTimestamp ||
        metadata.hasChangeset ||
        metadata.hasUserId ||
        metadata.hasUsername ||
        metadata.hasVisibility;

    if (!present)
        return;

    ++result.metadataElements;
    result.checksum = mix(result.checksum, metadata.hasVersion);
    result.checksum = mix(result.checksum, metadata.hasTimestamp);
    result.checksum = mix(result.checksum, metadata.hasChangeset);
    result.checksum = mix(result.checksum, metadata.hasUserId);
    result.checksum = mix(result.checksum, metadata.hasUsername);
    result.checksum = mix(result.checksum, metadata.hasVisibility);

    if (metadata.hasVersion)
        result.checksum = mix(result.checksum, cast(ulong)metadata.versionNumber);
    if (metadata.hasTimestamp)
        result.checksum = mix(result.checksum, cast(ulong)metadata.timestampMilliseconds);
    if (metadata.hasChangeset)
        result.checksum = mix(result.checksum, cast(ulong)metadata.changesetId);
    if (metadata.hasUserId)
        result.checksum = mix(result.checksum, cast(ulong)metadata.userId);
    if (metadata.hasUsername)
    {
        result.checksum = mix(result.checksum, metadata.username.length);
        if (metadata.username.length != 0)
        {
            result.checksum = mix(result.checksum, metadata.username[0]);
            result.checksum = mix(result.checksum, metadata.username[$ - 1]);
        }
    }
    if (metadata.hasVisibility)
        result.checksum = mix(result.checksum, cast(ulong)metadata.visible);
}

pragma(inline, true)
private void consumeWay(scope ref WayView value, ref Result result)
    @safe nothrow @nogc
{
    ++result.elements;
    result.checksum = mix(result.checksum, cast(ulong)value.id);
    consumeMetadata(value.metadata, result);
}

pragma(inline, true)
private void consumeRelation(scope ref RelationView value, ref Result result)
    @safe nothrow @nogc
{
    ++result.elements;
    result.checksum = mix(result.checksum, cast(ulong)value.id);
    consumeMetadata(value.metadata, result);
}

private bool runForeach(Mode mode)(const(ubyte)[] input, out Result result)
{
    PbfReader reader;
    Result local;

    static if (mode == Mode.way)
    {
        auto values = reader.ways(input);
        foreach (scope ref WayView value; values)
            consumeWay(value, local);
        if (!values.status.ok || !values.completed)
            return false;
    }
    else
    {
        auto values = reader.relations(input);
        foreach (scope ref RelationView value; values)
            consumeRelation(value, local);
        if (!values.status.ok || !values.completed)
            return false;
    }

    result = local;
    return true;
}

private bool runExplicit(Mode mode)(const(ubyte)[] input, out Result result)
{
    PbfReader reader;
    Result local;

    static if (mode == Mode.way)
    {
        int visit(scope ref WayView value) @safe
        {
            consumeWay(value, local);
            return 0;
        }

        auto values = reader.ways(input);
        const control = values.opApply(&visit);
        if (control != 0 || !values.status.ok || !values.completed)
            return false;
    }
    else
    {
        int visit(scope ref RelationView value) @safe
        {
            consumeRelation(value, local);
            return 0;
        }

        auto values = reader.relations(input);
        const control = values.opApply(&visit);
        if (control != 0 || !values.status.ok || !values.completed)
            return false;
    }

    result = local;
    return true;
}

private bool runOne(Mode mode)(
    string implementation,
    const(ubyte)[] input,
    out Result result)
{
    if (implementation == "foreach")
        return runForeach!mode(input, result);
    if (implementation == "explicit")
        return runExplicit!mode(input, result);
    return false;
}

private int runTimed(Mode mode)(string implementation, const(ubyte)[] input)
{
    Result warm;
    if (!runOne!mode(implementation, input, warm))
    {
        stderr.writefln("warm-up failed: %s", implementation);
        return 1;
    }

    Result result;
    StopWatch sw = StopWatch(AutoStart.yes);
    const ok = runOne!mode(implementation, input, result);
    sw.stop();

    if (!ok || result != warm)
    {
        stderr.writefln("timed run failed/non-deterministic: %s", implementation);
        return 1;
    }

    writefln("elapsed_ns=%s", sw.peek.total!"nsecs");
    writefln("elements=%s", result.elements);
    writefln("metadata_elements=%s", result.metadataElements);
    writefln("checksum=%016x", result.checksum);
    return 0;
}

int main(string[] args)
{
    if (args.length != 4)
    {
        stderr.writefln(
            "usage: %s foreach|explicit way|relation FILE.osm.pbf",
            args[0]);
        return 2;
    }

    auto storage = cast(ubyte[])read(args[3]);
    const input = cast(const(ubyte)[])storage;

    if (args[2] == "way")
        return runTimed!(Mode.way)(args[1], input);
    if (args[2] == "relation")
        return runTimed!(Mode.relation)(args[1], input);

    stderr.writefln("unknown mode: %s", args[2]);
    return 2;
}
D

echo
echo '=== BUILD ==='
(
    cd "$TMP"
    "$DUB" build         --compiler="$COMPILER"         --build=release         --build-mode=allAtOnce         --force
)

BIN="$TMP/bin/opapply-syntax-ab"
[[ -x "$BIN" ]] || fail "diagnostic executable missing"

run_pinned() { taskset -c "$CPU" "$@"; }
elapsed_ns() { awk -F= '/^elapsed_ns=/ {print $2; exit}'; }
extract_semantics() { grep -E '^(elements|metadata_elements|checksum)='; }

echo
echo '=== SEMANTIC PARITY ==='
for mode in way relation; do
    for impl in foreach explicit; do
        run_pinned "$BIN" "$impl" "$mode" "$DATA" |
            extract_semantics > "$TMP/$mode-$impl.txt"
    done
    diff -u "$TMP/$mode-foreach.txt" "$TMP/$mode-explicit.txt"
    echo "$mode: PARITY PASS"
    cat "$TMP/$mode-foreach.txt"
done

if [[ "$COOLDOWN" != "0" ]]; then
    echo
    echo "=== COOLDOWN: ${COOLDOWN}s ==="
    sleep "$COOLDOWN"
fi

OUT="$ROOT/benchmark/results/way-relation-opapply-syntax-ab-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
CSV="$OUT/samples.csv"
echo 'mode,block,position,implementation,elapsed_ns' > "$CSV"

echo
echo '=== TIMING ==='
for mode in way relation; do
    echo
    echo "=== MODE: $mode ==="
    for ((block=1; block<=BLOCKS; ++block)); do
        if (( block % 2 == 1 )); then
            seq=(foreach explicit explicit foreach)
            order="FEEF"
        else
            seq=(explicit foreach foreach explicit)
            order="EFFE"
        fi

        echo "--- block $block: $order ---"
        pos=0
        for impl in "${seq[@]}"; do
            ((++pos))
            ns="$(run_pinned "$BIN" "$impl" "$mode" "$DATA" | elapsed_ns)"
            printf '%-8s block=%s pos=%s  %s ns\n' "$impl" "$block" "$pos" "$ns"
            echo "$mode,$block,$pos,$impl,$ns" >> "$CSV"
            sleep "$GAP"
        done
    done

    if [[ "$mode" = "way" && "$COOLDOWN" != "0" ]]; then
        echo
        echo "=== INTER-MODE COOLDOWN: ${COOLDOWN}s ==="
        sleep "$COOLDOWN"
    fi
done

echo
echo '=== SUMMARY ==='
python3 - "$CSV" <<'PY'
import csv
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1], newline="")))

for mode in ("way", "relation"):
    print(f"[{mode}]")
    med = {}
    for impl in ("foreach", "explicit"):
        xs = [
            int(r["elapsed_ns"]) / 1e6
            for r in rows
            if r["mode"] == mode and r["implementation"] == impl
        ]
        med[impl] = statistics.median(xs)
        print(f"{impl:8s} n={len(xs)} p50={med[impl]:9.3f} ms")

    print(
        "explicit/foreach = "
        f"{(med['explicit']/med['foreach'] - 1.0)*100:+.2f}%"
    )
    print()
PY

echo "raw CSV: $CSV"
echo
echo '=== FINAL LOCAL GIT STATE ==='
git -C "$ROOT" status --short --branch
echo
echo "Resultate: $OUT"
