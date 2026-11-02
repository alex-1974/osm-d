#!/usr/bin/env bash
set -euo pipefail

ROOT="${OSM_D_ROOT:-$HOME/Programmiersprachen/dlang/d-geospatial-workspace/libs/osm-d}"
BRANCH="feat/pbf-way-relation-foreach"
CAND="fa596f88b4b3caf7692a0b9a4dc933198d6744a3"
DATASET_ID="${D_OSM_BENCH_DATASET:-bremen-260901}"
CPU="${D_OSM_BENCH_CPU:-5}"
BLOCKS="${D_OSM_BENCH_BLOCKS:-5}"
COOLDOWN="${D_OSM_BENCH_COOLDOWN:-30}"
GAP="${D_OSM_BENCH_GAP:-1}"
COMPILER="${D_OSM_BENCH_COMPILER:-ldc-1.41.0}"
DUB="${D_OSM_BENCH_DUB:-dub-dlang-baseline}"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -d "$ROOT/.git" ]] || fail "repository not found: $ROOT"
command -v "$COMPILER" >/dev/null 2>&1 || fail "compiler not found: $COMPILER"
command -v "$DUB" >/dev/null 2>&1 || fail "DUB not found: $DUB"
command -v taskset >/dev/null 2>&1 || fail "taskset not found"
[[ "$BLOCKS" =~ ^[1-9][0-9]*$ ]] || fail "D_OSM_BENCH_BLOCKS must be positive"

cd "$ROOT"

echo '=== FETCH / VERIFY ==='
git fetch origin develop "$BRANCH"
REMOTE="$(git rev-parse "origin/$BRANCH")"
echo "branch head: $REMOTE"
echo "candidate:   $CAND"
git merge-base --is-ancestor "$CAND" "origin/$BRANCH" ||
    fail "candidate $CAND is not an ancestor of origin/$BRANCH"

WT="$(mktemp -d /tmp/osm-d-way-relation-foreach-wt.XXXXXX)"
TMP="$(mktemp -d /tmp/osm-d-way-relation-foreach-src.XXXXXX)"
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

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/benchmark/results/way-relation-foreach-ab-$STAMP"
mkdir -p "$OUT"
CSV="$OUT/samples.csv"
ENV="$OUT/environment.txt"

cat > "$TMP/dub.sdl" <<EOF
name "osm-d-way-relation-foreach-ab"
description "Temporary direct-sink vs Way/Relation foreach qualification"
authors "OpenAI qualification helper"
license "MIT"
dependency "osm-d" path="$WT"
targetType "executable"
targetName "way-relation-foreach-ab"
targetPath "bin"
sourcePaths "source"
mainSourceFile "source/app.d"
EOF

mkdir -p "$TMP/source"
cat > "$TMP/source/app.d" <<'D'
module app;

import osm :
    MetadataView,
    PbfReadStatus,
    PbfReadSummary,
    PbfReader,
    PbfReaderWorkspace,
    RelationMemberView,
    RelationView,
    TagView,
    WayNodeView,
    WayView;

import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : stderr, writefln;

private enum Mode
{
    wayCore,
    wayFull,
    relationCore,
    relationFull,
}

private struct Result
{
    ulong checksum;
    size_t elements;
    size_t tags;
    size_t children;
    size_t metadataElements;
}

pragma(inline, true)
private ulong mix(ulong state, ulong value) @safe pure nothrow @nogc
{
    return state ^
        (value + 0x9e37_79b9_7f4a_7c15UL + (state << 6) + (state >> 2));
}

pragma(inline, true)
private void mixBoundaryBytes(
    ref ulong checksum,
    scope const(ubyte)[] value)
    @safe pure nothrow @nogc
{
    checksum = mix(checksum, value.length);
    if (value.length != 0)
    {
        checksum = mix(checksum, value[0]);
        checksum = mix(checksum, value[$ - 1]);
    }
}

pragma(inline, true)
private void consumeMetadata(
    MetadataView metadata,
    ref Result result)
    @safe nothrow @nogc
{
    const hasMetadata =
        metadata.hasVersion ||
        metadata.hasTimestamp ||
        metadata.hasChangeset ||
        metadata.hasUserId ||
        metadata.hasUsername ||
        metadata.hasVisibility;

    if (!hasMetadata)
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
        mixBoundaryBytes(result.checksum, metadata.username);
    if (metadata.hasVisibility)
        result.checksum = mix(result.checksum, cast(ulong)metadata.visible);
}

pragma(inline, true)
private void consumeTags(T)(scope ref T value, ref Result result)
    @safe nothrow @nogc
{
    auto tags = value.tags;
    while (!tags.empty)
    {
        TagView tag = tags.front;
        mixBoundaryBytes(result.checksum, tag.key);
        mixBoundaryBytes(result.checksum, tag.value);
        ++result.tags;
        tags.popFront();
    }
}

pragma(inline, true)
private void consumeWay(Mode mode)(
    scope ref WayView way,
    ref Result result)
    @safe nothrow @nogc
{
    ++result.elements;
    result.checksum = mix(result.checksum, cast(ulong)way.id);
    consumeMetadata(way.metadata, result);

    static if (mode == Mode.wayFull)
    {
        consumeTags(way, result);
        auto nodes = way.nodes;
        while (!nodes.empty)
        {
            WayNodeView node = nodes.front;
            result.checksum = mix(result.checksum, cast(ulong)node.id);
            result.checksum = mix(result.checksum, cast(ulong)node.hasLocation);

            if (node.hasLocation)
            {
                const location = node.location;
                result.checksum = mix(
                    result.checksum,
                    cast(ulong)location.latitudeNanodegrees);
                result.checksum = mix(
                    result.checksum,
                    cast(ulong)location.longitudeNanodegrees);
            }

            ++result.children;
            nodes.popFront();
        }
    }
}

pragma(inline, true)
private void consumeRelation(Mode mode)(
    scope ref RelationView relation,
    ref Result result)
    @safe nothrow @nogc
{
    ++result.elements;
    result.checksum = mix(result.checksum, cast(ulong)relation.id);
    consumeMetadata(relation.metadata, result);

    static if (mode == Mode.relationFull)
    {
        consumeTags(relation, result);
        auto members = relation.members;
        while (!members.empty)
        {
            RelationMemberView member = members.front;
            result.checksum = mix(result.checksum, cast(ulong)member.id);
            result.checksum = mix(result.checksum, cast(ulong)member.type);
            mixBoundaryBytes(result.checksum, member.role);

            ++result.children;
            members.popFront();
        }
    }
}

private struct WayHandler(Mode mode)
{
    Result result;

    void way(scope ref WayView way) @safe nothrow @nogc
    {
        consumeWay!mode(way, result);
    }
}

private struct RelationHandler(Mode mode)
{
    Result result;

    void relation(scope ref RelationView relation) @safe nothrow @nogc
    {
        consumeRelation!mode(relation, result);
    }
}

private bool runDirectWay(Mode mode)(const(ubyte)[] input, out Result result)
{
    PbfReader reader;
    PbfReaderWorkspace workspace;
    WayHandler!mode handler;
    PbfReadSummary summary;
    PbfReadStatus status;

    if (!reader.read(input, workspace, handler, summary, status))
        return false;

    if (summary.ways != handler.result.elements)
        return false;

    result = handler.result;
    return true;
}

private bool runDirectRelation(Mode mode)(const(ubyte)[] input, out Result result)
{
    PbfReader reader;
    PbfReaderWorkspace workspace;
    RelationHandler!mode handler;
    PbfReadSummary summary;
    PbfReadStatus status;

    if (!reader.read(input, workspace, handler, summary, status))
        return false;

    if (summary.relations != handler.result.elements)
        return false;

    result = handler.result;
    return true;
}

private bool runForeachWay(Mode mode)(const(ubyte)[] input, out Result result)
{
    PbfReader reader;
    auto ways = reader.ways(input);
    Result local;

    foreach (scope ref WayView way; ways)
        consumeWay!mode(way, local);

    if (!ways.status.ok || !ways.completed)
        return false;

    result = local;
    return true;
}

private bool runForeachRelation(Mode mode)(const(ubyte)[] input, out Result result)
{
    PbfReader reader;
    auto relations = reader.relations(input);
    Result local;

    foreach (scope ref RelationView relation; relations)
        consumeRelation!mode(relation, local);

    if (!relations.status.ok || !relations.completed)
        return false;

    result = local;
    return true;
}

private bool runOne(Mode mode)(
    string implementation,
    const(ubyte)[] input,
    out Result result)
{
    static if (mode == Mode.wayCore || mode == Mode.wayFull)
    {
        if (implementation == "direct")
            return runDirectWay!mode(input, result);
        return runForeachWay!mode(input, result);
    }
    else
    {
        if (implementation == "direct")
            return runDirectRelation!mode(input, result);
        return runForeachRelation!mode(input, result);
    }
}

private int runTimed(Mode mode)(string implementation, const(ubyte)[] input)
{
    Result warm;
    if (!runOne!mode(implementation, input, warm))
    {
        stderr.writefln("warm-up failed");
        return 1;
    }

    Result result;
    StopWatch sw = StopWatch(AutoStart.yes);
    const ok = runOne!mode(implementation, input, result);
    sw.stop();

    if (!ok)
    {
        stderr.writefln("timed run failed");
        return 1;
    }

    if (result != warm)
    {
        stderr.writefln("non-deterministic result after warm-up");
        return 1;
    }

    writefln("elapsed_ns=%s", sw.peek.total!"nsecs");
    writefln("elements=%s", result.elements);
    writefln("tags_seen=%s", result.tags);
    writefln("children_seen=%s", result.children);
    writefln("metadata_elements=%s", result.metadataElements);
    writefln("checksum=%016x", result.checksum);
    return 0;
}

int main(string[] args)
{
    if (args.length != 4)
    {
        stderr.writefln(
            "usage: %s direct|foreach way-core|way-full|relation-core|relation-full FILE.osm.pbf",
            args[0]);
        return 2;
    }

    auto storage = cast(ubyte[])read(args[3]);
    const input = cast(const(ubyte)[])storage;

    switch (args[2])
    {
    case "way-core":
        return runTimed!(Mode.wayCore)(args[1], input);
    case "way-full":
        return runTimed!(Mode.wayFull)(args[1], input);
    case "relation-core":
        return runTimed!(Mode.relationCore)(args[1], input);
    case "relation-full":
        return runTimed!(Mode.relationFull)(args[1], input);
    default:
        stderr.writefln("unknown mode: %s", args[2]);
        return 2;
    }
}
D

echo
echo '=== BUILD ==='
(
    cd "$TMP"
    "$DUB" build \
        --compiler="$COMPILER" \
        --build=release \
        --build-mode=allAtOnce \
        --force
)

BIN="$TMP/bin/way-relation-foreach-ab"
[[ -x "$BIN" ]] || fail "benchmark executable missing"

{
    echo "candidate=$CAND"
    echo "dataset_id=$DATASET_ID"
    echo "dataset=$DATA"
    echo "dataset_sha256=$(sha256sum "$DATA" | awk '{print $1}')"
    echo "compiler=$COMPILER"
    "$COMPILER" --version | head -n 4
    echo "dub=$DUB"
    "$DUB" --version
    echo "cpu=$CPU"
    lscpu | grep -E 'Model name|Socket|Core|Thread' || true
    uname -a
} > "$ENV" 2>&1

run_pinned() { taskset -c "$CPU" "$@"; }
extract_semantics() { grep -E '^(elements|tags_seen|children_seen|metadata_elements|checksum)='; }
elapsed_ns() { awk -F= '/^elapsed_ns=/ {print $2; exit}'; }

read -r -a modes <<< "${D_OSM_BENCH_MODES:-way-core way-full relation-core relation-full}"

echo
echo '=== SEMANTIC PARITY ==='
for mode in "${modes[@]}"; do
    DOUT="$(run_pinned "$BIN" direct "$mode" "$DATA")"
    FOUT="$(run_pinned "$BIN" foreach "$mode" "$DATA")"

    printf '%s\n' "$DOUT" | extract_semantics > "$TMP/direct-$mode.txt"
    printf '%s\n' "$FOUT" | extract_semantics > "$TMP/foreach-$mode.txt"

    if diff -u "$TMP/direct-$mode.txt" "$TMP/foreach-$mode.txt"; then
        echo "$mode: PARITY PASS"
        cat "$TMP/direct-$mode.txt"
    else
        echo "$mode: PARITY FAIL" >&2
        exit 1
    fi
done

if [[ "$COOLDOWN" != "0" ]]; then
    echo
    echo "=== POST-BUILD COOLDOWN: ${COOLDOWN}s ==="
    sleep "$COOLDOWN"
fi

printf '%s\n' 'mode,block,position,order,implementation,elapsed_ns' > "$CSV"

mode_index=0
for mode in "${modes[@]}"; do
    ((++mode_index))
    echo
    echo "========================================"
    echo "=== MODE: $mode ==="
    echo "========================================"

    for ((block=1; block<=BLOCKS; ++block)); do
        echo "--- block $block ---"
        if (( block % 2 == 1 )); then
            order="DFFD"
            seq=(direct foreach foreach direct)
        else
            order="FDDF"
            seq=(foreach direct direct foreach)
        fi

        pos=0
        for impl in "${seq[@]}"; do
            ((++pos))
            ns="$(run_pinned "$BIN" "$impl" "$mode" "$DATA" | elapsed_ns)"
            printf '%-8s block=%s pos=%s  %s ns\n' "$impl" "$block" "$pos" "$ns"
            printf '%s,%s,%s,%s,%s,%s\n' \
                "$mode" "$block" "$pos" "$order" "$impl" "$ns" >> "$CSV"
            sleep "$GAP"
        done
    done

    if (( mode_index < ${#modes[@]} )) && [[ "$COOLDOWN" != "0" ]]; then
        echo
        echo "=== INTER-MODE COOLDOWN: ${COOLDOWN}s ==="
        sleep "$COOLDOWN"
    fi
done

echo
echo '=== SUMMARY ==='
python3 - "$CSV" <<'PY'
import csv
import sys

path = sys.argv[1]

def percentile(values, q):
    xs = sorted(values)
    if len(xs) == 1:
        return xs[0]
    pos = (len(xs) - 1) * q
    lo = int(pos)
    hi = min(lo + 1, len(xs) - 1)
    w = pos - lo
    return xs[lo] * (1 - w) + xs[hi] * w

data = {}
with open(path, newline="") as f:
    for row in csv.DictReader(f):
        data.setdefault((row["mode"], row["implementation"]), []).append(
            int(row["elapsed_ns"]) / 1e6
        )

for mode in dict.fromkeys(row["mode"] for row in csv.DictReader(open(path, newline=""))):
    print(f"[{mode}]")
    med = {}
    for impl in ("direct", "foreach"):
        xs = data[(mode, impl)]
        p10 = percentile(xs, 0.10)
        p50 = percentile(xs, 0.50)
        p90 = percentile(xs, 0.90)
        med[impl] = p50
        print(
            f"{impl:8s} n={len(xs)} "
            f"p10={p10:9.3f} p50={p50:9.3f} p90={p90:9.3f} ms"
        )
    delta = (med["foreach"] / med["direct"] - 1.0) * 100.0
    print(f"delta foreach/direct = {delta:+.2f}%")
    print()
PY

echo "raw CSV: $CSV"
echo "environment: $ENV"

echo
echo '=== FINAL LOCAL GIT STATE ==='
git -C "$ROOT" status --short --branch
echo
echo "Resultate: $OUT"
