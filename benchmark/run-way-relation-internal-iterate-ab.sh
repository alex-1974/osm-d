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

WT="$(mktemp -d /tmp/osm-d-internal-iterate-wt.XXXXXX)"
TMP="$(mktemp -d /tmp/osm-d-internal-iterate-src.XXXXXX)"
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

cat >> "$WT/source/osm/io/pbf/reader.d" <<'D'

import osm.view.metadata : MetadataView;

/*
 * TEMPORARY BENCHMARK HOOK.
 *
 * This code is appended only inside the detached benchmark worktree created by
 * benchmark/run-way-relation-internal-iterate-ab.sh. It is never committed to
 * the library candidate. The purpose is to compare the exact private
 * iterateSelected/decode*DataBlock path with a static sink and the production
 * delegate sink without an external reimplementation of reader orchestration.
 */
package(osm) struct ReaderInternalIterationBenchResult
{
    ulong checksum;
    size_t elements;
    size_t metadataElements;
}

pragma(inline, true)
private ulong benchMix(ulong state, ulong value)
    @safe pure nothrow @nogc
{
    return state ^
        (value + 0x9e37_79b9_7f4a_7c15UL + (state << 6) + (state >> 2));
}

pragma(inline, true)
private void benchConsumeMetadata(
    MetadataView metadata,
    ref ReaderInternalIterationBenchResult result)
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
    result.checksum = benchMix(result.checksum, metadata.hasVersion);
    result.checksum = benchMix(result.checksum, metadata.hasTimestamp);
    result.checksum = benchMix(result.checksum, metadata.hasChangeset);
    result.checksum = benchMix(result.checksum, metadata.hasUserId);
    result.checksum = benchMix(result.checksum, metadata.hasUsername);
    result.checksum = benchMix(result.checksum, metadata.hasVisibility);

    if (metadata.hasVersion)
        result.checksum = benchMix(
            result.checksum,
            cast(ulong)metadata.versionNumber);
    if (metadata.hasTimestamp)
        result.checksum = benchMix(
            result.checksum,
            cast(ulong)metadata.timestampMilliseconds);
    if (metadata.hasChangeset)
        result.checksum = benchMix(
            result.checksum,
            cast(ulong)metadata.changesetId);
    if (metadata.hasUserId)
        result.checksum = benchMix(
            result.checksum,
            cast(ulong)metadata.userId);
    if (metadata.hasUsername)
    {
        result.checksum = benchMix(
            result.checksum,
            metadata.username.length);
        if (metadata.username.length != 0)
        {
            result.checksum = benchMix(
                result.checksum,
                metadata.username[0]);
            result.checksum = benchMix(
                result.checksum,
                metadata.username[$ - 1]);
        }
    }
    if (metadata.hasVisibility)
        result.checksum = benchMix(
            result.checksum,
            cast(ulong)metadata.visible);
}

private struct ReaderInternalStaticWaySink
{
    ReaderInternalIterationBenchResult result;

    void putDenseNodeScalars(long, long, long) @safe nothrow @nogc {}
    void put(scope ref DenseNodeView) @safe nothrow @nogc {}
    void put(scope ref pbfNode.NodeView) @safe nothrow @nogc {}

    int put(scope ref WayView value) @safe nothrow @nogc
    {
        ++result.elements;
        result.checksum = benchMix(
            result.checksum,
            cast(ulong)value.id);
        benchConsumeMetadata(value.metadata, result);
        return 0;
    }

    void put(scope ref RelationView) @safe nothrow @nogc {}
}

private struct ReaderInternalStaticRelationSink
{
    ReaderInternalIterationBenchResult result;

    void putDenseNodeScalars(long, long, long) @safe nothrow @nogc {}
    void put(scope ref DenseNodeView) @safe nothrow @nogc {}
    void put(scope ref pbfNode.NodeView) @safe nothrow @nogc {}
    void put(scope ref WayView) @safe nothrow @nogc {}

    int put(scope ref RelationView value) @safe nothrow @nogc
    {
        ++result.elements;
        result.checksum = benchMix(
            result.checksum,
            cast(ulong)value.id);
        benchConsumeMetadata(value.metadata, result);
        return 0;
    }
}

package(osm)
bool benchmarkInternalStaticWays(
    const(ubyte)[] input,
    out ReaderInternalIterationBenchResult result)
{
    PbfReaderWorkspace workspace;
    ReaderInternalStaticWaySink sink;
    int control;
    PbfReadStatus status;

    const ok = iterateSelected!decodeWayDataBlock(
        input,
        workspace,
        sink,
        control,
        status);

    result = sink.result;
    return ok && control == 0 && status.ok;
}

package(osm)
bool benchmarkInternalDelegateWays(
    const(ubyte)[] input,
    scope int delegate(scope ref WayView) @safe dg,
    out PbfReadStatus status,
    out bool completed)
{
    PbfReaderWorkspace workspace;
    SafeWayForeachSink sink = SafeWayForeachSink(dg);
    int control;

    completed = false;
    const ok = iterateSelected!decodeWayDataBlock(
        input,
        workspace,
        sink,
        control,
        status);

    if (!ok || control != 0)
        return ok;

    completed = true;
    return true;
}

package(osm)
bool benchmarkInternalStaticRelations(
    const(ubyte)[] input,
    out ReaderInternalIterationBenchResult result)
{
    PbfReaderWorkspace workspace;
    ReaderInternalStaticRelationSink sink;
    int control;
    PbfReadStatus status;

    const ok = iterateSelected!decodeRelationDataBlock(
        input,
        workspace,
        sink,
        control,
        status);

    result = sink.result;
    return ok && control == 0 && status.ok;
}

package(osm)
bool benchmarkInternalDelegateRelations(
    const(ubyte)[] input,
    scope int delegate(scope ref RelationView) @safe dg,
    out PbfReadStatus status,
    out bool completed)
{
    PbfReaderWorkspace workspace;
    SafeRelationForeachSink sink = SafeRelationForeachSink(dg);
    int control;

    completed = false;
    const ok = iterateSelected!decodeRelationDataBlock(
        input,
        workspace,
        sink,
        control,
        status);

    if (!ok || control != 0)
        return ok;

    completed = true;
    return true;
}
D

cat > "$TMP/dub.sdl" <<EOF
name "osm-d-internal-iterate-ab"
description "Temporary exact iterateSelected static/delegate/public diagnostic"
authors "OpenAI qualification helper"
license "MIT"
dependency "osm-d" path="$WT"
targetType "executable"
targetName "internal-iterate-ab"
targetPath "bin"
sourcePaths "source"
mainSourceFile "source/app.d"
EOF

mkdir -p "$TMP/source"
cat > "$TMP/source/app.d" <<'D'
module osm.benchmark.internal_iterate_ab;

import osm :
    MetadataView,
    PbfReadStatus,
    PbfReader,
    RelationView,
    WayView;
import osm.io.pbf.reader :
    ReaderInternalIterationBenchResult,
    benchmarkInternalDelegateRelations,
    benchmarkInternalDelegateWays,
    benchmarkInternalStaticRelations,
    benchmarkInternalStaticWays;

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
        result.checksum = mix(
            result.checksum,
            cast(ulong)metadata.versionNumber);
    if (metadata.hasTimestamp)
        result.checksum = mix(
            result.checksum,
            cast(ulong)metadata.timestampMilliseconds);
    if (metadata.hasChangeset)
        result.checksum = mix(
            result.checksum,
            cast(ulong)metadata.changesetId);
    if (metadata.hasUserId)
        result.checksum = mix(
            result.checksum,
            cast(ulong)metadata.userId);
    if (metadata.hasUsername)
    {
        result.checksum = mix(result.checksum, metadata.username.length);
        if (metadata.username.length != 0)
        {
            result.checksum = mix(
                result.checksum,
                metadata.username[0]);
            result.checksum = mix(
                result.checksum,
                metadata.username[$ - 1]);
        }
    }
    if (metadata.hasVisibility)
        result.checksum = mix(
            result.checksum,
            cast(ulong)metadata.visible);
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

private Result convert(ReaderInternalIterationBenchResult value)
    @safe pure nothrow @nogc
{
    return Result(
        value.checksum,
        value.elements,
        value.metadataElements);
}

private bool runStatic(Mode mode)(const(ubyte)[] input, out Result result)
{
    ReaderInternalIterationBenchResult internal;
    static if (mode == Mode.way)
        const ok = benchmarkInternalStaticWays(input, internal);
    else
        const ok = benchmarkInternalStaticRelations(input, internal);

    result = convert(internal);
    return ok;
}

private bool runInternalDelegate(Mode mode)(
    const(ubyte)[] input,
    out Result result)
{
    Result local;
    PbfReadStatus status;
    bool completed;

    static if (mode == Mode.way)
    {
        int visit(scope ref WayView value) @safe
        {
            consumeWay(value, local);
            return 0;
        }

        const ok = benchmarkInternalDelegateWays(
            input,
            &visit,
            status,
            completed);
    }
    else
    {
        int visit(scope ref RelationView value) @safe
        {
            consumeRelation(value, local);
            return 0;
        }

        const ok = benchmarkInternalDelegateRelations(
            input,
            &visit,
            status,
            completed);
    }

    result = local;
    return ok && status.ok && completed;
}

private bool runPublic(Mode mode)(const(ubyte)[] input, out Result result)
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
    if (implementation == "static")
        return runStatic!mode(input, result);
    if (implementation == "delegate")
        return runInternalDelegate!mode(input, result);
    if (implementation == "public")
        return runPublic!mode(input, result);
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
        stderr.writefln(
            "timed run failed/non-deterministic: %s",
            implementation);
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
            "usage: %s static|delegate|public way|relation FILE.osm.pbf",
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

BIN="$TMP/bin/internal-iterate-ab"
[[ -x "$BIN" ]] || fail "diagnostic executable missing"

run_pinned() { taskset -c "$CPU" "$@"; }
elapsed_ns() { awk -F= '/^elapsed_ns=/ {print $2; exit}'; }
extract_semantics() { grep -E '^(elements|metadata_elements|checksum)='; }

echo
echo '=== SEMANTIC PARITY ==='
for mode in way relation; do
    for impl in static delegate public; do
        run_pinned "$BIN" "$impl" "$mode" "$DATA" |
            extract_semantics > "$TMP/$mode-$impl.txt"
    done

    diff -u "$TMP/$mode-static.txt" "$TMP/$mode-delegate.txt"
    diff -u "$TMP/$mode-static.txt" "$TMP/$mode-public.txt"
    echo "$mode: PARITY PASS"
    cat "$TMP/$mode-static.txt"
done

if [[ "$COOLDOWN" != "0" ]]; then
    echo
    echo "=== COOLDOWN: ${COOLDOWN}s ==="
    sleep "$COOLDOWN"
fi

OUT="$ROOT/benchmark/results/way-relation-internal-iterate-ab-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
CSV="$OUT/samples.csv"
echo 'mode,block,position,implementation,elapsed_ns' > "$CSV"

orders=(
    "static delegate public"
    "static public delegate"
    "delegate static public"
    "delegate public static"
    "public static delegate"
    "public delegate static"
)

echo
echo '=== TIMING ==='
for mode in way relation; do
    echo
    echo "=== MODE: $mode ==="

    for ((block=1; block<=BLOCKS; ++block)); do
        order="${orders[$(((block - 1) % ${#orders[@]}))]}"
        read -r -a seq <<< "$order"
        echo "--- block $block: $order ---"

        pos=0
        for impl in "${seq[@]}"; do
            ((++pos))
            ns="$(run_pinned "$BIN" "$impl" "$mode" "$DATA" | elapsed_ns)"
            printf '%-8s block=%s pos=%s  %s ns\n'                 "$impl" "$block" "$pos" "$ns"
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
    for impl in ("static", "delegate", "public"):
        xs = [
            int(r["elapsed_ns"]) / 1e6
            for r in rows
            if r["mode"] == mode and r["implementation"] == impl
        ]
        med[impl] = statistics.median(xs)
        print(f"{impl:8s} n={len(xs)} p50={med[impl]:9.3f} ms")

    print(
        "delegate/static = "
        f"{(med['delegate']/med['static'] - 1.0)*100:+.2f}%"
    )
    print(
        "public/delegate = "
        f"{(med['public']/med['delegate'] - 1.0)*100:+.2f}%"
    )
    print(
        "public/static   = "
        f"{(med['public']/med['static'] - 1.0)*100:+.2f}%"
    )
    print()
PY

echo "raw CSV: $CSV"
echo
echo '=== FINAL LOCAL GIT STATE ==='
git -C "$ROOT" status --short --branch
echo
echo "Resultate: $OUT"
