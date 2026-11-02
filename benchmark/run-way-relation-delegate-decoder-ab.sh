#!/usr/bin/env bash
set -euo pipefail

ROOT="${OSM_D_ROOT:-$HOME/Programmiersprachen/dlang/d-geospatial-workspace/libs/osm-d}"
BRANCH="feat/pbf-way-relation-foreach"
CAND="e6726cab74b089a709b9911fdad0910c698d8101"
DATASET_ID="${D_OSM_BENCH_DATASET:-bremen-260901}"
CPU="${D_OSM_BENCH_CPU:-5}"
SAMPLES="${D_OSM_BENCH_SAMPLES:-12}"
COOLDOWN="${D_OSM_BENCH_COOLDOWN:-20}"
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

WT="$(mktemp -d /tmp/osm-d-delegate-decoder-wt.XXXXXX)"
TMP="$(mktemp -d /tmp/osm-d-delegate-decoder-src.XXXXXX)"
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
name "osm-d-delegate-decoder-ab"
description "Temporary static sink vs delegate sink decoder diagnostic"
authors "OpenAI qualification helper"
license "MIT"
dependency "osm-d" path="$WT"
targetType "executable"
targetName "delegate-decoder-ab"
targetPath "bin"
sourcePaths "source"
mainSourceFile "source/app.d"
EOF

mkdir -p "$TMP/source"
cat > "$TMP/source/app.d" <<'D'
module osm.benchmark.delegate_decoder_ab;

import osm :
    MetadataView,
    RelationView,
    WayView;

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
    decodeRelationsUntilStop;
import osm.io.pbf.string_table :
    StringRef,
    StringTableView,
    buildStringTableView;
import osm.io.pbf.way :
    WayDecodePlan,
    WayDecodeSummary,
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

private struct StaticWaySink
{
    Result result;

    int put(scope ref WayView value) @safe nothrow @nogc
    {
        consumeWay(value, result);
        return 0;
    }
}

private struct StaticRelationSink
{
    Result result;

    int put(scope ref RelationView value) @safe nothrow @nogc
    {
        consumeRelation(value, result);
        return 0;
    }
}

private struct DelegateWaySink
{
    int delegate(scope ref WayView) @safe nothrow @nogc dg;

    this(scope int delegate(scope ref WayView) @safe nothrow @nogc value)
        @trusted nothrow @nogc
    {
        dg = value;
    }

    int put(scope ref WayView value) @safe nothrow @nogc
    {
        return dg(value);
    }
}

private struct DelegateRelationSink
{
    int delegate(scope ref RelationView) @safe nothrow @nogc dg;

    this(scope int delegate(scope ref RelationView) @safe nothrow @nogc value)
        @trusted nothrow @nogc
    {
        dg = value;
    }

    int put(scope ref RelationView value) @safe nothrow @nogc
    {
        return dg(value);
    }
}

private long timeWay(
    bool useDelegate,
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    WayDecodePlan[] plans,
    out Result result)
{
    int control;
    WayDecodeSummary summary;
    PbfStatus status;

    if (!useDelegate)
    {
        StaticWaySink sink;
        StopWatch sw = StopWatch(AutoStart.yes);
        const ok = decodeWaysWithWorkspaceUntilStop(
            block, group, table, plans, sink, control, summary, status);
        sw.stop();

        if (!ok || !status.ok || control != 0 ||
            summary.wayCount != sink.result.elements)
            return -1;

        result = sink.result;
        return sw.peek.total!"nsecs";
    }

    Result local;
    int consume(scope ref WayView value) @safe nothrow @nogc
    {
        consumeWay(value, local);
        return 0;
    }

    DelegateWaySink sink = DelegateWaySink(&consume);
    StopWatch sw = StopWatch(AutoStart.yes);
    const ok = decodeWaysWithWorkspaceUntilStop(
        block, group, table, plans, sink, control, summary, status);
    sw.stop();

    if (!ok || !status.ok || control != 0 ||
        summary.wayCount != local.elements)
        return -1;

    result = local;
    return sw.peek.total!"nsecs";
}

private long timeRelation(
    bool useDelegate,
    ref const PrimitiveBlockLayout block,
    ref const PrimitiveGroupLayout group,
    StringTableView table,
    out Result result)
{
    int control;
    RelationDecodeSummary summary;
    PbfStatus status;

    if (!useDelegate)
    {
        StaticRelationSink sink;
        StopWatch sw = StopWatch(AutoStart.yes);
        const ok = decodeRelationsUntilStop(
            block, group, table, sink, control, summary, status);
        sw.stop();

        if (!ok || !status.ok || control != 0 ||
            summary.relationCount != sink.result.elements)
            return -1;

        result = sink.result;
        return sw.peek.total!"nsecs";
    }

    Result local;
    int consume(scope ref RelationView value) @safe nothrow @nogc
    {
        consumeRelation(value, local);
        return 0;
    }

    DelegateRelationSink sink = DelegateRelationSink(&consume);
    StopWatch sw = StopWatch(AutoStart.yes);
    const ok = decodeRelationsUntilStop(
        block, group, table, sink, control, summary, status);
    sw.stop();

    if (!ok || !status.ok || control != 0 ||
        summary.relationCount != local.elements)
        return -1;

    result = local;
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
    size_t pairIndex;
    long staticWayNs;
    long delegateWayNs;
    long staticRelationNs;
    long delegateRelationNs;
    Result staticWayResult;
    Result delegateWayResult;
    Result staticRelationResult;
    Result delegateRelationResult;

    while (true)
    {
        FileBlockView fileBlock;
        PbfStatus status;
        const frameResult =
            readFileBlock(cursor, sequence, fileBlock, status);

        if (frameResult == FrameReadResult.endOfInput)
            break;
        if (frameResult != FrameReadResult.block)
            return 3;

        BlobView blob;
        if (!decodeBlob(fileBlock.blob, blob, status))
            return 3;

        const outputSize = requiredOutputSize(blob);
        if (decompressionBuffer.length < outputSize)
            decompressionBuffer.length = outputSize;

        BlobPayloadView payload;
        if (!decodeBlobPayloadInto(
                blob,
                decompressionBuffer,
                payload,
                status))
            return 3;

        if (fileBlock.header.kind != BlobKind.osmData)
        {
            ++sequence;
            continue;
        }

        PrimitiveBlockLayout block;
        if (!decodePrimitiveBlockLayout(payload.bytes, block, status))
            return 3;

        if (stringRefs.length < block.stringCount)
            stringRefs.length = block.stringCount;

        StringTableView table;
        if (!buildStringTableView(
                block,
                stringRefs[0 .. block.stringCount],
                table,
                status))
            return 3;

        auto groups = block.primitiveGroups;
        while (!groups.empty)
        {
            const groupRef = groups.front;
            groups.popFront();

            PrimitiveGroupLayout group;
            if (!decodePrimitiveGroupLayout(groupRef.bytes, group, status))
                return 3;

            if (group.wayOccurrences != 0)
            {
                if (wayPlans.length < group.wayOccurrences)
                    wayPlans.length = group.wayOccurrences;
                auto plans = wayPlans[0 .. group.wayOccurrences];

                Result a;
                Result b;
                long aNs;
                long bNs;

                if ((pairIndex & 1) == 0)
                {
                    aNs = timeWay(false, block, group, table, plans, a);
                    bNs = timeWay(true, block, group, table, plans, b);
                }
                else
                {
                    bNs = timeWay(true, block, group, table, plans, b);
                    aNs = timeWay(false, block, group, table, plans, a);
                }

                if (aNs < 0 || bNs < 0 || a != b)
                    return 4;

                staticWayNs += aNs;
                delegateWayNs += bNs;
                staticWayResult.checksum = mix(
                    staticWayResult.checksum, a.checksum);
                staticWayResult.elements += a.elements;
                staticWayResult.metadataElements += a.metadataElements;
                delegateWayResult.checksum = mix(
                    delegateWayResult.checksum, b.checksum);
                delegateWayResult.elements += b.elements;
                delegateWayResult.metadataElements += b.metadataElements;
                ++pairIndex;
            }
            else if (group.relationOccurrences != 0)
            {
                Result a;
                Result b;
                long aNs;
                long bNs;

                if ((pairIndex & 1) == 0)
                {
                    aNs = timeRelation(false, block, group, table, a);
                    bNs = timeRelation(true, block, group, table, b);
                }
                else
                {
                    bNs = timeRelation(true, block, group, table, b);
                    aNs = timeRelation(false, block, group, table, a);
                }

                if (aNs < 0 || bNs < 0 || a != b)
                    return 4;

                staticRelationNs += aNs;
                delegateRelationNs += bNs;
                staticRelationResult.checksum = mix(
                    staticRelationResult.checksum, a.checksum);
                staticRelationResult.elements += a.elements;
                staticRelationResult.metadataElements += a.metadataElements;
                delegateRelationResult.checksum = mix(
                    delegateRelationResult.checksum, b.checksum);
                delegateRelationResult.elements += b.elements;
                delegateRelationResult.metadataElements += b.metadataElements;
                ++pairIndex;
            }
        }

        ++sequence;
    }

    if (staticWayResult != delegateWayResult ||
        staticRelationResult != delegateRelationResult)
        return 4;

    writefln("ways=%s", staticWayResult.elements);
    writefln("static_way_ns=%s", staticWayNs);
    writefln("delegate_way_ns=%s", delegateWayNs);
    writefln("relations=%s", staticRelationResult.elements);
    writefln("static_relation_ns=%s", staticRelationNs);
    writefln("delegate_relation_ns=%s", delegateRelationNs);
    return 0;
}
D

echo
echo '=== BUILD ==='
(
    cd "$TMP"
    "$DUB" build         --compiler="$COMPILER"         --build=release         --build-mode=allAtOnce         --force
)

BIN="$TMP/bin/delegate-decoder-ab"
[[ -x "$BIN" ]] || fail "diagnostic executable missing"

if [[ "$COOLDOWN" != "0" ]]; then
    echo
    echo "=== COOLDOWN: ${COOLDOWN}s ==="
    sleep "$COOLDOWN"
fi

OUT="$ROOT/benchmark/results/way-relation-delegate-decoder-ab-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
CSV="$OUT/samples.csv"
echo 'sample,ways,static_way_ns,delegate_way_ns,relations,static_relation_ns,delegate_relation_ns' > "$CSV"

echo
echo '=== SAMPLES ==='
for ((sample=1; sample<=SAMPLES; ++sample)); do
    RESULT="$(taskset -c "$CPU" "$BIN" "$DATA")"
    ways="$(awk -F= '/^ways=/ {print $2}' <<<"$RESULT")"
    sway="$(awk -F= '/^static_way_ns=/ {print $2}' <<<"$RESULT")"
    dway="$(awk -F= '/^delegate_way_ns=/ {print $2}' <<<"$RESULT")"
    rels="$(awk -F= '/^relations=/ {print $2}' <<<"$RESULT")"
    srel="$(awk -F= '/^static_relation_ns=/ {print $2}' <<<"$RESULT")"
    drel="$(awk -F= '/^delegate_relation_ns=/ {print $2}' <<<"$RESULT")"

    echo "sample=$sample way static=$sway delegate=$dway relation static=$srel delegate=$drel"
    echo "$sample,$ways,$sway,$dway,$rels,$srel,$drel" >> "$CSV"
done

echo
echo '=== SUMMARY ==='
python3 - "$CSV" <<'PY'
import csv
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1], newline="")))

def report(label, static_name, delegate_name):
    s = [int(r[static_name]) / 1e6 for r in rows]
    d = [int(r[delegate_name]) / 1e6 for r in rows]
    sm = statistics.median(s)
    dm = statistics.median(d)
    paired = [(dv/sv - 1.0) * 100 for sv, dv in zip(s, d)]
    print(f"[{label}]")
    print(f"static   p50 = {sm:.3f} ms")
    print(f"delegate p50 = {dm:.3f} ms")
    print(f"median-ratio delta = {(dm/sm - 1.0)*100:+.2f}%")
    print(f"paired median delta = {statistics.median(paired):+.2f}%")
    print()

report("Way decoder", "static_way_ns", "delegate_way_ns")
report("Relation decoder", "static_relation_ns", "delegate_relation_ns")
PY

echo "raw CSV: $CSV"
echo
echo '=== FINAL LOCAL GIT STATE ==='
git -C "$ROOT" status --short --branch
echo
echo "Resultate: $OUT"
