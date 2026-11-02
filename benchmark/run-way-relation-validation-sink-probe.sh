#!/usr/bin/env bash
set -euo pipefail

ROOT="${OSM_D_ROOT:-$HOME/Programmiersprachen/dlang/d-geospatial-workspace/libs/osm-d}"
BRANCH="feat/pbf-way-relation-foreach"
CAND="e6726cab74b089a709b9911fdad0910c698d8101"
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

cd "$ROOT"

echo '=== FETCH / VERIFY ==='
git fetch origin develop "$BRANCH"
REMOTE="$(git rev-parse "origin/$BRANCH")"
echo "branch head: $REMOTE"
echo "candidate:   $CAND"
git merge-base --is-ancestor "$CAND" "origin/$BRANCH" ||
    fail "candidate $CAND is not an ancestor of origin/$BRANCH"

WT="$(mktemp -d /tmp/osm-d-validation-sink-wt.XXXXXX)"
TMP="$(mktemp -d /tmp/osm-d-validation-sink-src.XXXXXX)"
cleanup() {
    git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true
    rm -rf "$WT" "$TMP" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git worktree add --detach "$WT" "$CAND"

python3 - "$WT/source/osm/io/pbf/reader.d" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

insert_before = """private bool decodeWayDataBlock(Sink)(
"""
validation_sink = r"""
/*
 * Diagnostic production candidate:
 * validate non-selected primitive kinds with a stateless sink.
 *
 * The selected Way/Relation still uses the original stop-aware sink. Every
 * non-selected decoder still executes its complete validation path; only its
 * unobservable callback target no longer carries the foreach delegate.
 */
private struct SelectedIterationValidationSink
{
    void putDenseNodeScalars(long, long, long) @safe nothrow @nogc {}
    void put(scope ref DenseNodeView) @safe nothrow @nogc {}
    void put(scope ref pbfNode.NodeView) @safe nothrow @nogc {}
    void put(scope ref WayView) @safe nothrow @nogc {}
    void put(scope ref RelationView) @safe nothrow @nogc {}
}

"""

if text.count(insert_before) != 1:
    raise SystemExit("decodeWayDataBlock declaration not uniquely found")
text = text.replace(insert_before, validation_sink + insert_before, 1)

way_old = r"""        DenseNodeDecodeSummary denseSummary;
        if (!decodeDenseNodes(
                block,
                group,
                table,
                sink,
                denseSummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        pbfNode.NodeDecodeSummary nodeSummary;
        if (!pbfNode.decodeNodes(
                block,
                group,
                table,
                sink,
                nodeSummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (workspace.wayPlans.length < group.wayOccurrences)
            workspace.wayPlans.length = group.wayOccurrences;

        WayDecodeSummary waySummary;
        if (!decodeWaysWithWorkspaceUntilStop(
                block,
                group,
                table,
                workspace.wayPlans[0 .. group.wayOccurrences],
                sink,
                control,
                waySummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (control != 0)
        {
            readStatus = PbfReadStatus.init;
            return true;
        }

        RelationDecodeSummary relationSummary;
        if (!decodeRelations(
                block,
                group,
                table,
                sink,
                relationSummary,
                status))
"""

way_new = r"""        SelectedIterationValidationSink validationSink;

        DenseNodeDecodeSummary denseSummary;
        if (!decodeDenseNodes(
                block,
                group,
                table,
                validationSink,
                denseSummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        pbfNode.NodeDecodeSummary nodeSummary;
        if (!pbfNode.decodeNodes(
                block,
                group,
                table,
                validationSink,
                nodeSummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (workspace.wayPlans.length < group.wayOccurrences)
            workspace.wayPlans.length = group.wayOccurrences;

        WayDecodeSummary waySummary;
        if (!decodeWaysWithWorkspaceUntilStop(
                block,
                group,
                table,
                workspace.wayPlans[0 .. group.wayOccurrences],
                sink,
                control,
                waySummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (control != 0)
        {
            readStatus = PbfReadStatus.init;
            return true;
        }

        RelationDecodeSummary relationSummary;
        if (!decodeRelations(
                block,
                group,
                table,
                validationSink,
                relationSummary,
                status))
"""

if text.count(way_old) != 1:
    raise SystemExit(f"Way selected-reader block match count={text.count(way_old)}")
text = text.replace(way_old, way_new, 1)

relation_old = r"""        DenseNodeDecodeSummary denseSummary;
        if (!decodeDenseNodes(
                block,
                group,
                table,
                sink,
                denseSummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        pbfNode.NodeDecodeSummary nodeSummary;
        if (!pbfNode.decodeNodes(
                block,
                group,
                table,
                sink,
                nodeSummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (workspace.wayPlans.length < group.wayOccurrences)
            workspace.wayPlans.length = group.wayOccurrences;

        WayDecodeSummary waySummary;
        if (!decodeWaysWithWorkspace(
                block,
                group,
                table,
                workspace.wayPlans[0 .. group.wayOccurrences],
                sink,
                waySummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        RelationDecodeSummary relationSummary;
        if (!decodeRelationsUntilStop(
                block,
                group,
                table,
                sink,
                control,
                relationSummary,
                status))
"""

relation_new = r"""        SelectedIterationValidationSink validationSink;

        DenseNodeDecodeSummary denseSummary;
        if (!decodeDenseNodes(
                block,
                group,
                table,
                validationSink,
                denseSummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        pbfNode.NodeDecodeSummary nodeSummary;
        if (!pbfNode.decodeNodes(
                block,
                group,
                table,
                validationSink,
                nodeSummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        if (workspace.wayPlans.length < group.wayOccurrences)
            workspace.wayPlans.length = group.wayOccurrences;

        WayDecodeSummary waySummary;
        if (!decodeWaysWithWorkspace(
                block,
                group,
                table,
                workspace.wayPlans[0 .. group.wayOccurrences],
                validationSink,
                waySummary,
                status))
        {
            readStatus = fromPbfFailure(
                sequence,
                fileBlockOffset,
                status);
            return false;
        }

        RelationDecodeSummary relationSummary;
        if (!decodeRelationsUntilStop(
                block,
                group,
                table,
                sink,
                control,
                relationSummary,
                status))
"""

if text.count(relation_old) != 1:
    raise SystemExit(
        f"Relation selected-reader block match count={text.count(relation_old)}"
    )
text = text.replace(relation_old, relation_new, 1)

path.write_text(text)
PY

echo
echo '=== PATCH VERIFY ==='
grep -n -A12 -B4 'SelectedIterationValidationSink'     "$WT/source/osm/io/pbf/reader.d"

DATA_DIR="${D_OSM_BENCH_DATA_DIR:-$ROOT/benchmark/data/geofabrik-2026-09-01}"
if ! OSM_D_BENCH_DATA="$DATA_DIR" "$WT/benchmark/fetch-datasets.sh" verify "$DATASET_ID"; then
    OSM_D_BENCH_DATA="$DATA_DIR" "$WT/benchmark/fetch-datasets.sh" fetch "$DATASET_ID"
fi

MANIFEST="$WT/benchmark/datasets/geofabrik-2026-09-01.tsv"
DATASET_FILE="$(awk -F '\t' -v id="$DATASET_ID" '$1 == id {print $7; exit}' "$MANIFEST")"
[[ -n "$DATASET_FILE" ]] || fail "dataset not found in manifest: $DATASET_ID"
DATA="$DATA_DIR/$DATASET_FILE"

cat > "$TMP/dub.sdl" <<EOF
name "osm-d-validation-sink-probe"
description "Temporary selected-iteration validation-sink performance probe"
authors "OpenAI qualification helper"
license "MIT"
dependency "osm-d" path="$WT"
targetType "executable"
targetName "validation-sink-probe"
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

    if (!status.ok || summary.ways != handler.result.elements)
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

    if (!status.ok || summary.relations != handler.result.elements)
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

    if (!ok || result != warm)
    {
        stderr.writefln("timed run failed/non-deterministic");
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
    "$DUB" build         --compiler="$COMPILER"         --build=release         --build-mode=allAtOnce         --force
)

BIN="$TMP/bin/validation-sink-probe"
[[ -x "$BIN" ]] || fail "benchmark executable missing"

run_pinned() { taskset -c "$CPU" "$@"; }
extract_semantics() { grep -E '^(elements|tags_seen|children_seen|metadata_elements|checksum)='; }
elapsed_ns() { awk -F= '/^elapsed_ns=/ {print $2; exit}'; }

echo
echo '=== SEMANTIC PARITY ==='
for mode in way-core way-full relation-core relation-full; do
    DOUT="$(run_pinned "$BIN" direct "$mode" "$DATA")"
    FOUT="$(run_pinned "$BIN" foreach "$mode" "$DATA")"

    printf '%s\n' "$DOUT" | extract_semantics > "$TMP/direct-$mode.txt"
    printf '%s\n' "$FOUT" | extract_semantics > "$TMP/foreach-$mode.txt"

    diff -u "$TMP/direct-$mode.txt" "$TMP/foreach-$mode.txt"
    echo "$mode: PARITY PASS"
    cat "$TMP/direct-$mode.txt"
done

if [[ "$COOLDOWN" != "0" ]]; then
    echo
    echo "=== COOLDOWN: ${COOLDOWN}s ==="
    sleep "$COOLDOWN"
fi

OUT="$ROOT/benchmark/results/way-relation-validation-sink-probe-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
CSV="$OUT/samples.csv"
echo 'mode,block,position,implementation,elapsed_ns' > "$CSV"

mode_index=0
for mode in way-core way-full relation-core relation-full; do
    ((++mode_index))
    echo
    echo "=== MODE: $mode ==="

    for ((block=1; block<=BLOCKS; ++block)); do
        if (( block % 2 == 1 )); then
            seq=(direct foreach foreach direct)
            order="DFFD"
        else
            seq=(foreach direct direct foreach)
            order="FDDF"
        fi

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

    if (( mode_index < 4 )) && [[ "$COOLDOWN" != "0" ]]; then
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

for mode in ("way-core", "way-full", "relation-core", "relation-full"):
    print(f"[{mode}]")
    med = {}
    for impl in ("direct", "foreach"):
        xs = [
            int(r["elapsed_ns"]) / 1e6
            for r in rows
            if r["mode"] == mode and r["implementation"] == impl
        ]
        med[impl] = statistics.median(xs)
        print(f"{impl:8s} n={len(xs)} p50={med[impl]:9.3f} ms")

    print(
        "foreach/direct = "
        f"{(med['foreach']/med['direct'] - 1.0)*100:+.2f}%"
    )
    print()
PY

echo "raw CSV: $CSV"
echo
echo '=== FINAL LOCAL GIT STATE ==='
git -C "$ROOT" status --short --branch
echo
echo "Resultate: $OUT"
