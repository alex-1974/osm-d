#!/usr/bin/env bash
set -euo pipefail

ROOT="${OSM_D_ROOT:-$HOME/Programmiersprachen/dlang/d-geospatial-workspace/libs/osm-d}"
BRANCH="feat/pbf-way-relation-foreach"
CAND="bc37345630a08807ca3506ac9b25db7858f35a2f"
DATASET_ID="${D_OSM_BENCH_DATASET:-bremen-260901}"
CPU="${D_OSM_BENCH_CPU:-5}"
SAMPLES="${D_OSM_BENCH_SAMPLES:-10}"
COOLDOWN="${D_OSM_BENCH_COOLDOWN:-20}"
COMPILER="${D_OSM_BENCH_COMPILER:-ldc-1.41.0}"
DUB="${D_OSM_BENCH_DUB:-dub-dlang-baseline}"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -d "$ROOT/.git" ]] || fail "repository not found: $ROOT"
command -v "$COMPILER" >/dev/null 2>&1 || fail "compiler not found: $COMPILER"
command -v "$DUB" >/dev/null 2>&1 || fail "DUB not found: $DUB"
command -v taskset >/dev/null 2>&1 || fail "taskset not found"
[[ "$SAMPLES" =~ ^[1-9][0-9]*$ ]] || fail "D_OSM_BENCH_SAMPLES must be positive"

cd "$ROOT"
echo '=== FETCH / VERIFY ==='
git fetch origin develop "$BRANCH"
REMOTE="$(git rev-parse "origin/$BRANCH")"
echo "branch head: $REMOTE"
echo "candidate:   $CAND"
git merge-base --is-ancestor "$CAND" "origin/$BRANCH" ||
    fail "candidate $CAND is not an ancestor of origin/$BRANCH"

WT="$(mktemp -d /tmp/osm-d-decoder-stop-wt.XXXXXX)"
TMP="$(mktemp -d /tmp/osm-d-decoder-stop-src.XXXXXX)"
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
name "osm-d-decoder-stop-ab"
description "Temporary direct vs stop-aware Way/Relation decoder diagnostic"
authors "OpenAI qualification helper"
license "MIT"
dependency "osm-d" path="$WT"
targetType "executable"
targetName "decoder-stop-ab"
targetPath "bin"
sourcePaths "source"
mainSourceFile "source/app.d"
EOF

mkdir -p "$TMP/source"
cat > "$TMP/source/app.d" <<'D'
module osm.benchmark.decoder_stop_ab;

import osm.io.pbf.blob : BlobView, decodeBlob;
import osm.io.pbf.blob_header : BlobKind;
import osm.io.pbf.decompress :
    BlobPayloadView,
    decodeBlobPayloadInto,
    requiredOutputSize;
import osm.io.pbf.error : PbfStatus;
import osm.io.pbf.framing :
    FileBlockView,
    FrameReadResult,
    readFileBlock;
import osm.io.pbf.primitive_block :
    PrimitiveBlockLayout,
    decodePrimitiveBlockLayout;
import osm.io.pbf.primitive_group :
    PrimitiveGroupLayout,
    decodePrimitiveGroupLayout;
import osm.io.pbf.relation :
    RelationDecodeSummary,
    RelationView,
    decodeRelations,
    decodeRelationsUntilStop;
import osm.io.pbf.string_table :
    StringRef,
    StringTableView,
    buildStringTableView;
import osm.io.pbf.way :
    WayDecodePlan,
    WayDecodeSummary,
    WayView,
    decodeWaysWithWorkspace,
    decodeWaysWithWorkspaceUntilStop;
import osm.wire.cursor : WireCursor;

import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : stderr, writefln;

private struct Result
{
    ulong checksum;
    size_t count;
}

pragma(inline, true)
private ulong mix(ulong state, ulong value) @safe pure nothrow @nogc
{
    return state ^
        (value + 0x9e37_79b9_7f4a_7c15UL + (state << 6) + (state >> 2));
}

pragma(inline, true)
private void consumeWay(scope ref WayView value, ref Result result)
    @safe nothrow @nogc
{
    ++result.count;
    result.checksum = mix(result.checksum, cast(ulong)value.id);

    const metadata = value.metadata;
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
private void consumeRelation(scope ref RelationView value, ref Result result)
    @safe nothrow @nogc
{
    ++result.count;
    result.checksum = mix(result.checksum, cast(ulong)value.id);

    const metadata = value.metadata;
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

private struct DirectWaySink
{
    Result result;
    void put(scope ref WayView value) @safe nothrow @nogc
    {
        consumeWay(value, result);
    }
}

private struct StopWaySink
{
    Result result;
    int put(scope ref WayView value) @safe nothrow @nogc
    {
        consumeWay(value, result);
        return 0;
    }
}

private struct DirectRelationSink
{
    Result result;
    void put(scope ref RelationView value) @safe nothrow @nogc
    {
        consumeRelation(value, result);
    }
}

private struct StopRelationSink
{
    Result result;
    int put(scope ref RelationView value) @safe nothrow @nogc
    {
        consumeRelation(value, result);
        return 0;
    }
}

private long timeDirectWay(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    WayDecodePlan[] plans,
    out Result result)
{
    DirectWaySink sink;
    WayDecodeSummary summary;
    PbfStatus status;

    StopWatch sw = StopWatch(AutoStart.yes);
    const ok = decodeWaysWithWorkspace(
        block, group, table, plans, sink, summary, status);
    sw.stop();

    if (!ok || !status.ok || summary.wayCount != sink.result.count)
        return -1;

    result = sink.result;
    return sw.peek.total!"nsecs";
}

private long timeStopWay(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    WayDecodePlan[] plans,
    out Result result)
{
    StopWaySink sink;
    int control;
    WayDecodeSummary summary;
    PbfStatus status;

    StopWatch sw = StopWatch(AutoStart.yes);
    const ok = decodeWaysWithWorkspaceUntilStop(
        block, group, table, plans, sink, control, summary, status);
    sw.stop();

    if (!ok || !status.ok || control != 0 ||
        summary.wayCount != sink.result.count)
        return -1;

    result = sink.result;
    return sw.peek.total!"nsecs";
}

private long timeDirectRelation(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    out Result result)
{
    DirectRelationSink sink;
    RelationDecodeSummary summary;
    PbfStatus status;

    StopWatch sw = StopWatch(AutoStart.yes);
    const ok = decodeRelations(
        block, group, table, sink, summary, status);
    sw.stop();

    if (!ok || !status.ok || summary.relationCount != sink.result.count)
        return -1;

    result = sink.result;
    return sw.peek.total!"nsecs";
}

private long timeStopRelation(
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    out Result result)
{
    StopRelationSink sink;
    int control;
    RelationDecodeSummary summary;
    PbfStatus status;

    StopWatch sw = StopWatch(AutoStart.yes);
    const ok = decodeRelationsUntilStop(
        block, group, table, sink, control, summary, status);
    sw.stop();

    if (!ok || !status.ok || control != 0 ||
        summary.relationCount != sink.result.count)
        return -1;

    result = sink.result;
    return sw.peek.total!"nsecs";
}

int main(string[] args)
{
    if (args.length != 2)
    {
        stderr.writefln("usage: %s FILE.osm.pbf", args[0]);
        return 2;
    }

    auto storage = cast(ubyte[])read(args[1]);
    const input = cast(const(ubyte)[])storage;
    auto cursor = WireCursor(input);

    ubyte[] decompressionBuffer;
    StringRef[] stringRefs;
    WayDecodePlan[] wayPlans;

    ulong sequence;
    size_t targetGroupIndex;
    long directWayNs;
    long stopWayNs;
    long directRelationNs;
    long stopRelationNs;
    Result directWayResult;
    Result stopWayResult;
    Result directRelationResult;
    Result stopRelationResult;

    while (true)
    {
        FileBlockView fileBlock;
        PbfStatus status;
        const frameResult =
            readFileBlock(cursor, sequence, fileBlock, status);

        if (frameResult == FrameReadResult.endOfInput)
            break;
        if (frameResult != FrameReadResult.block)
        {
            stderr.writefln("framing failure at block %s", sequence);
            return 3;
        }

        BlobView blob;
        if (!decodeBlob(fileBlock.blob, blob, status))
        {
            stderr.writefln("blob failure at block %s", sequence);
            return 3;
        }

        const outputSize = requiredOutputSize(blob);
        if (decompressionBuffer.length < outputSize)
            decompressionBuffer.length = outputSize;

        BlobPayloadView payload;
        if (!decodeBlobPayloadInto(
                blob,
                decompressionBuffer,
                payload,
                status))
        {
            stderr.writefln("decompression failure at block %s", sequence);
            return 3;
        }

        if (fileBlock.header.kind != BlobKind.osmData)
        {
            ++sequence;
            continue;
        }

        PrimitiveBlockLayout block;
        if (!decodePrimitiveBlockLayout(payload.bytes, block, status))
        {
            stderr.writefln("PrimitiveBlock failure at block %s", sequence);
            return 3;
        }

        if (stringRefs.length < block.stringCount)
            stringRefs.length = block.stringCount;

        StringTableView table;
        if (!buildStringTableView(
                block,
                stringRefs[0 .. block.stringCount],
                table,
                status))
        {
            stderr.writefln("StringTable failure at block %s", sequence);
            return 3;
        }

        auto groups = block.primitiveGroups;
        while (!groups.empty)
        {
            const groupRef = groups.front;
            groups.popFront();

            PrimitiveGroupLayout group;
            if (!decodePrimitiveGroupLayout(groupRef.bytes, group, status))
            {
                stderr.writefln("PrimitiveGroup failure at block %s", sequence);
                return 3;
            }

            if (group.wayOccurrences != 0)
            {
                if (wayPlans.length < group.wayOccurrences)
                    wayPlans.length = group.wayOccurrences;
                auto plans = wayPlans[0 .. group.wayOccurrences];

                Result a;
                Result b;
                long aNs;
                long bNs;

                if ((targetGroupIndex & 1) == 0)
                {
                    aNs = timeDirectWay(block, group, table, plans, a);
                    bNs = timeStopWay(block, group, table, plans, b);
                }
                else
                {
                    bNs = timeStopWay(block, group, table, plans, b);
                    aNs = timeDirectWay(block, group, table, plans, a);
                }

                if (aNs < 0 || bNs < 0 || a != b)
                {
                    stderr.writefln("Way parity failure at block %s", sequence);
                    return 4;
                }

                directWayNs += aNs;
                stopWayNs += bNs;
                directWayResult.checksum = mix(
                    directWayResult.checksum, a.checksum);
                directWayResult.count += a.count;
                stopWayResult.checksum = mix(
                    stopWayResult.checksum, b.checksum);
                stopWayResult.count += b.count;
                ++targetGroupIndex;
            }
            else if (group.relationOccurrences != 0)
            {
                Result a;
                Result b;
                long aNs;
                long bNs;

                if ((targetGroupIndex & 1) == 0)
                {
                    aNs = timeDirectRelation(block, group, table, a);
                    bNs = timeStopRelation(block, group, table, b);
                }
                else
                {
                    bNs = timeStopRelation(block, group, table, b);
                    aNs = timeDirectRelation(block, group, table, a);
                }

                if (aNs < 0 || bNs < 0 || a != b)
                {
                    stderr.writefln(
                        "Relation parity failure at block %s", sequence);
                    return 4;
                }

                directRelationNs += aNs;
                stopRelationNs += bNs;
                directRelationResult.checksum = mix(
                    directRelationResult.checksum, a.checksum);
                directRelationResult.count += a.count;
                stopRelationResult.checksum = mix(
                    stopRelationResult.checksum, b.checksum);
                stopRelationResult.count += b.count;
                ++targetGroupIndex;
            }
        }

        ++sequence;
    }

    if (directWayResult != stopWayResult ||
        directRelationResult != stopRelationResult)
    {
        stderr.writefln("aggregate semantic parity failure");
        return 4;
    }

    writefln("ways=%s", directWayResult.count);
    writefln("way_checksum=%016x", directWayResult.checksum);
    writefln("direct_way_ns=%s", directWayNs);
    writefln("stop_way_ns=%s", stopWayNs);
    writefln("relations=%s", directRelationResult.count);
    writefln("relation_checksum=%016x", directRelationResult.checksum);
    writefln("direct_relation_ns=%s", directRelationNs);
    writefln("stop_relation_ns=%s", stopRelationNs);
    return 0;
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

BIN="$TMP/bin/decoder-stop-ab"
[[ -x "$BIN" ]] || fail "diagnostic executable missing"

if [[ "$COOLDOWN" != "0" ]]; then
    echo
    echo "=== COOLDOWN: ${COOLDOWN}s ==="
    sleep "$COOLDOWN"
fi

OUT="$ROOT/benchmark/results/way-relation-decoder-stop-ab-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
CSV="$OUT/samples.csv"
echo 'sample,ways,direct_way_ns,stop_way_ns,relations,direct_relation_ns,stop_relation_ns' > "$CSV"

echo
echo '=== SAMPLES ==='
for ((sample=1; sample<=SAMPLES; ++sample)); do
    RESULT="$(taskset -c "$CPU" "$BIN" "$DATA")"
    ways="$(awk -F= '/^ways=/ {print $2}' <<<"$RESULT")"
    dway="$(awk -F= '/^direct_way_ns=/ {print $2}' <<<"$RESULT")"
    sway="$(awk -F= '/^stop_way_ns=/ {print $2}' <<<"$RESULT")"
    rels="$(awk -F= '/^relations=/ {print $2}' <<<"$RESULT")"
    drel="$(awk -F= '/^direct_relation_ns=/ {print $2}' <<<"$RESULT")"
    srel="$(awk -F= '/^stop_relation_ns=/ {print $2}' <<<"$RESULT")"
    echo "sample=$sample way direct=$dway stop=$sway relation direct=$drel stop=$srel"
    echo "$sample,$ways,$dway,$sway,$rels,$drel,$srel" >> "$CSV"
done

echo
echo '=== SUMMARY ==='
python3 - "$CSV" <<'PY'
import csv, statistics, sys

rows = list(csv.DictReader(open(sys.argv[1], newline="")))

def vals(name):
    return [int(r[name]) / 1e6 for r in rows]

def report(label, direct_name, stop_name):
    direct = vals(direct_name)
    stop = vals(stop_name)
    dmed = statistics.median(direct)
    smed = statistics.median(stop)
    deltas = [(s/d - 1.0) * 100 for d, s in zip(direct, stop)]
    print(f"[{label}]")
    print(f"direct p50 = {dmed:.3f} ms")
    print(f"stop   p50 = {smed:.3f} ms")
    print(f"median ratio delta = {(smed/dmed - 1.0)*100:+.2f}%")
    print(f"paired median delta = {statistics.median(deltas):+.2f}%")
    print()

report("Way decoder only", "direct_way_ns", "stop_way_ns")
report("Relation decoder only", "direct_relation_ns", "stop_relation_ns")
PY

echo "raw CSV: $CSV"
echo
echo '=== FINAL LOCAL GIT STATE ==='
git -C "$ROOT" status --short --branch
echo
echo "Resultate: $OUT"
