#!/usr/bin/env bash
set -euo pipefail

ROOT="${OSM_D_ROOT:-$HOME/Programmiersprachen/dlang/d-geospatial-workspace/libs/osm-d}"
BRANCH="feat/pbf-way-relation-foreach"
CAND="e6726cab74b089a709b9911fdad0910c698d8101"
DATASET_ID="${D_OSM_BENCH_DATASET:-bremen-260901}"
CPU="${D_OSM_BENCH_CPU:-5}"
BLOCKS="${D_OSM_BENCH_BLOCKS:-4}"
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

WT="$(mktemp -d /tmp/osm-d-reader-layer-wt.XXXXXX)"
TMP="$(mktemp -d /tmp/osm-d-reader-layer-src.XXXXXX)"
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
name "osm-d-reader-layer-ab"
description "Temporary direct reader vs static selected vs foreach diagnostic"
authors "OpenAI qualification helper"
license "MIT"
dependency "osm-d" path="$WT"
targetType "executable"
targetName "reader-layer-ab"
targetPath "bin"
sourcePaths "source"
mainSourceFile "source/app.d"
EOF

mkdir -p "$TMP/source"
cat > "$TMP/source/app.d" <<'D'
module osm.benchmark.reader_layer_ab;

import osm :
    MetadataView,
    PbfReadStatus,
    PbfReadSummary,
    PbfReader,
    PbfReaderWorkspace,
    RelationView,
    WayView;

import osm.io.pbf.blob : BlobView, decodeBlob;
import osm.io.pbf.blob_header : BlobKind;
import osm.io.pbf.decompress :
    BlobPayloadView,
    decodeBlobPayloadInto,
    requiredOutputSize;
import osm.io.pbf.dense_nodes :
    DenseNodeDecodeSummary,
    DenseNodeView,
    decodeDenseNodes;
import osm.io.pbf.error : PbfStatus;
import osm.io.pbf.features :
    HeaderFeatureAssessment,
    HeaderFeatureSupport,
    validateRequiredFeatures;
import osm.io.pbf.framing :
    FileBlockView,
    FrameReadResult,
    readFileBlock;
import osm.io.pbf.header_block : HeaderBlockView, decodeHeaderBlock;
import pbfNode = osm.io.pbf.node;
import osm.io.pbf.primitive_block :
    PrimitiveBlockLayout,
    decodePrimitiveBlockLayout;
import osm.io.pbf.primitive_group :
    PrimitiveGroupLayout,
    decodePrimitiveGroupLayout;
import osm.io.pbf.relation :
    RelationDecodeSummary,
    decodeRelations,
    decodeRelationsUntilStop;
import osm.io.pbf.string_table :
    StringRef,
    StringTableView,
    buildStringTableView;
import osm.io.pbf.way :
    WayDecodePlan,
    WayDecodeSummary,
    decodeWaysWithWorkspace,
    decodeWaysWithWorkspaceUntilStop;
import osm.wire.cursor : WireCursor;

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
private void consumeWay(scope ref WayView way, ref Result result)
    @safe nothrow @nogc
{
    ++result.elements;
    result.checksum = mix(result.checksum, cast(ulong)way.id);
    consumeMetadata(way.metadata, result);
}

pragma(inline, true)
private void consumeRelation(scope ref RelationView relation, ref Result result)
    @safe nothrow @nogc
{
    ++result.elements;
    result.checksum = mix(result.checksum, cast(ulong)relation.id);
    consumeMetadata(relation.metadata, result);
}

private struct DirectWayHandler
{
    Result result;

    void way(scope ref WayView value) @safe nothrow @nogc
    {
        consumeWay(value, result);
    }
}

private struct DirectRelationHandler
{
    Result result;

    void relation(scope ref RelationView value) @safe nothrow @nogc
    {
        consumeRelation(value, result);
    }
}

private struct StaticWaySink
{
    Result result;

    void putDenseNodeScalars(long, long, long) @safe nothrow @nogc {}
    void put(scope ref DenseNodeView) @safe nothrow @nogc {}
    void put(scope ref pbfNode.NodeView) @safe nothrow @nogc {}

    int put(scope ref WayView value) @safe nothrow @nogc
    {
        consumeWay(value, result);
        return 0;
    }

    void put(scope ref RelationView) @safe nothrow @nogc {}
}

private struct StaticRelationSink
{
    Result result;

    void putDenseNodeScalars(long, long, long) @safe nothrow @nogc {}
    void put(scope ref DenseNodeView) @safe nothrow @nogc {}
    void put(scope ref pbfNode.NodeView) @safe nothrow @nogc {}
    void put(scope ref WayView) @safe nothrow @nogc {}

    int put(scope ref RelationView value) @safe nothrow @nogc
    {
        consumeRelation(value, result);
        return 0;
    }
}

private struct LocalWorkspace
{
    ubyte[] decompressionBuffer;
    StringRef[] stringRefs;
    WayDecodePlan[] wayPlans;
}

private bool validateHeader(const(ubyte)[] payload, out PbfStatus status)
{
    HeaderBlockView header;
    if (!decodeHeaderBlock(payload, header, status))
        return false;

    HeaderFeatureAssessment assessment;
    return validateRequiredFeatures(
        header,
        HeaderFeatureSupport.allKnown(),
        assessment,
        status);
}

private bool decodeWayBlock(
    const(ubyte)[] payloadBytes,
    ref LocalWorkspace workspace,
    ref StaticWaySink sink)
{
    PbfStatus status;
    PrimitiveBlockLayout block;
    if (!decodePrimitiveBlockLayout(payloadBytes, block, status))
        return false;

    if (workspace.stringRefs.length < block.stringCount)
        workspace.stringRefs.length = block.stringCount;

    StringTableView table;
    if (!buildStringTableView(
            block,
            workspace.stringRefs[0 .. block.stringCount],
            table,
            status))
        return false;

    auto groups = block.primitiveGroups;
    while (!groups.empty)
    {
        const groupRef = groups.front;
        groups.popFront();

        PrimitiveGroupLayout group;
        if (!decodePrimitiveGroupLayout(groupRef.bytes, group, status))
            return false;
        if (group.changeSetOccurrences != 0)
            return false;

        DenseNodeDecodeSummary denseSummary;
        if (!decodeDenseNodes(
                block, group, table, sink, denseSummary, status))
            return false;

        pbfNode.NodeDecodeSummary nodeSummary;
        if (!pbfNode.decodeNodes(
                block, group, table, sink, nodeSummary, status))
            return false;

        if (workspace.wayPlans.length < group.wayOccurrences)
            workspace.wayPlans.length = group.wayOccurrences;

        int control;
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
            return false;
        if (control != 0)
            return false;

        RelationDecodeSummary relationSummary;
        if (!decodeRelations(
                block, group, table, sink, relationSummary, status))
            return false;
    }

    return true;
}

private bool decodeRelationBlock(
    const(ubyte)[] payloadBytes,
    ref LocalWorkspace workspace,
    ref StaticRelationSink sink)
{
    PbfStatus status;
    PrimitiveBlockLayout block;
    if (!decodePrimitiveBlockLayout(payloadBytes, block, status))
        return false;

    if (workspace.stringRefs.length < block.stringCount)
        workspace.stringRefs.length = block.stringCount;

    StringTableView table;
    if (!buildStringTableView(
            block,
            workspace.stringRefs[0 .. block.stringCount],
            table,
            status))
        return false;

    auto groups = block.primitiveGroups;
    while (!groups.empty)
    {
        const groupRef = groups.front;
        groups.popFront();

        PrimitiveGroupLayout group;
        if (!decodePrimitiveGroupLayout(groupRef.bytes, group, status))
            return false;
        if (group.changeSetOccurrences != 0)
            return false;

        DenseNodeDecodeSummary denseSummary;
        if (!decodeDenseNodes(
                block, group, table, sink, denseSummary, status))
            return false;

        pbfNode.NodeDecodeSummary nodeSummary;
        if (!pbfNode.decodeNodes(
                block, group, table, sink, nodeSummary, status))
            return false;

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
            return false;

        int control;
        RelationDecodeSummary relationSummary;
        if (!decodeRelationsUntilStop(
                block,
                group,
                table,
                sink,
                control,
                relationSummary,
                status))
            return false;
        if (control != 0)
            return false;
    }

    return true;
}

private bool runStaticSelected(Mode mode)(
    const(ubyte)[] input,
    out Result result)
{
    LocalWorkspace workspace;
    static if (mode == Mode.way)
        StaticWaySink sink;
    else
        StaticRelationSink sink;

    auto cursor = WireCursor(input);
    bool sawHeader;
    bool sawData;
    ulong sequence;

    while (true)
    {
        FileBlockView fileBlock;
        PbfStatus status;
        const frameResult =
            readFileBlock(cursor, sequence, fileBlock, status);

        if (frameResult == FrameReadResult.endOfInput)
            break;
        if (frameResult != FrameReadResult.block)
            return false;

        BlobView blob;
        if (!decodeBlob(fileBlock.blob, blob, status))
            return false;

        const outputSize = requiredOutputSize(blob);
        if (workspace.decompressionBuffer.length < outputSize)
            workspace.decompressionBuffer.length = outputSize;

        BlobPayloadView payload;
        if (!decodeBlobPayloadInto(
                blob,
                workspace.decompressionBuffer,
                payload,
                status))
            return false;

        final switch (fileBlock.header.kind)
        {
        case BlobKind.osmHeader:
            if (sawHeader || sawData)
                return false;
            if (!validateHeader(payload.bytes, status))
                return false;
            sawHeader = true;
            break;

        case BlobKind.osmData:
            if (!sawHeader)
                return false;
            sawData = true;
            static if (mode == Mode.way)
            {
                if (!decodeWayBlock(payload.bytes, workspace, sink))
                    return false;
            }
            else
            {
                if (!decodeRelationBlock(payload.bytes, workspace, sink))
                    return false;
            }
            break;

        case BlobKind.unknown:
            return false;
        }

        ++sequence;
    }

    if (!sawHeader)
        return false;

    result = sink.result;
    return true;
}

private bool runDirect(Mode mode)(const(ubyte)[] input, out Result result)
{
    PbfReader reader;
    PbfReaderWorkspace workspace;
    PbfReadSummary summary;
    PbfReadStatus status;

    static if (mode == Mode.way)
    {
        DirectWayHandler handler;
        if (!reader.read(input, workspace, handler, summary, status))
            return false;
        if (!status.ok || summary.ways != handler.result.elements)
            return false;
        result = handler.result;
    }
    else
    {
        DirectRelationHandler handler;
        if (!reader.read(input, workspace, handler, summary, status))
            return false;
        if (!status.ok || summary.relations != handler.result.elements)
            return false;
        result = handler.result;
    }

    return true;
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

private bool runOne(Mode mode)(
    string implementation,
    const(ubyte)[] input,
    out Result result)
{
    if (implementation == "direct")
        return runDirect!mode(input, result);
    if (implementation == "static")
        return runStaticSelected!mode(input, result);
    if (implementation == "foreach")
        return runForeach!mode(input, result);
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
            "usage: %s direct|static|foreach way|relation FILE.osm.pbf",
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

BIN="$TMP/bin/reader-layer-ab"
[[ -x "$BIN" ]] || fail "diagnostic executable missing"

run_pinned() { taskset -c "$CPU" "$@"; }
elapsed_ns() { awk -F= '/^elapsed_ns=/ {print $2; exit}'; }
extract_semantics() { grep -E '^(elements|metadata_elements|checksum)='; }

echo
echo '=== SEMANTIC PARITY ==='
for mode in way relation; do
    for impl in direct static foreach; do
        run_pinned "$BIN" "$impl" "$mode" "$DATA" |
            extract_semantics > "$TMP/$mode-$impl.txt"
    done
    diff -u "$TMP/$mode-direct.txt" "$TMP/$mode-static.txt"
    diff -u "$TMP/$mode-direct.txt" "$TMP/$mode-foreach.txt"
    echo "$mode: PARITY PASS"
    cat "$TMP/$mode-direct.txt"
done

if [[ "$COOLDOWN" != "0" ]]; then
    echo
    echo "=== COOLDOWN: ${COOLDOWN}s ==="
    sleep "$COOLDOWN"
fi

OUT="$ROOT/benchmark/results/way-relation-reader-layer-ab-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
CSV="$OUT/samples.csv"
echo 'mode,block,position,implementation,elapsed_ns' > "$CSV"

orders=(
    "direct static foreach"
    "direct foreach static"
    "static direct foreach"
    "static foreach direct"
    "foreach direct static"
    "foreach static direct"
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
    for impl in ("direct", "static", "foreach"):
        xs = [
            int(r["elapsed_ns"]) / 1e6
            for r in rows
            if r["mode"] == mode and r["implementation"] == impl
        ]
        med[impl] = statistics.median(xs)
        print(f"{impl:8s} n={len(xs)} p50={med[impl]:9.3f} ms")

    print(
        "static/direct  = "
        f"{(med['static']/med['direct'] - 1.0)*100:+.2f}%"
    )
    print(
        "foreach/static = "
        f"{(med['foreach']/med['static'] - 1.0)*100:+.2f}%"
    )
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
