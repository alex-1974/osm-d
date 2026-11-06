#!/usr/bin/env bash
set -euo pipefail

if (($# != 2)); then
    echo "usage: benchmark/area/build-osmium-reference.sh <input.osm.pbf> <output.tsv>" >&2
    exit 2
fi

input=$1
output=$2

command -v osmium >/dev/null 2>&1 || {
    echo "osmium not found" >&2
    exit 2
}
command -v jq >/dev/null 2>&1 || {
    echo "jq not found" >&2
    exit 2
}

mkdir -p "$(dirname "$output")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

matches="$tmp/multipolygon-relations.osm.pbf"
filtered="$tmp/multipolygons-complete.osm.pbf"
geojson="$tmp/multipolygons.geojson"
errors="${output%.tsv}.osmium-errors.txt"

# First isolate only the matching Relation identities. Then recursively recover
# every referenced Way and Node from the original snapshot. This avoids relying
# on tags-filter to provide transitive Relation -> Way -> Node completeness.
echo "oracle_stage=tags-filter"
osmium tags-filter \
    --verbose \
    --omit-referenced \
    --overwrite \
    -o "$matches" \
    "$input" \
    r/type=multipolygon

echo "matched_relations=$(osmium fileinfo -e -g data.count.relations "$matches")"
echo "oracle_stage=getid"
set +e
osmium getid \
    --verbose \
    --add-referenced \
    --id-osm-file="$matches" \
    --overwrite \
    -o "$filtered" \
    "$input"
getid_status=$?
set -e

# osmium getid returns 1 when requested/referenced objects are absent. Pinned
# regional extracts can legitimately be partial at their boundary. The output
# still contains every available recursively referenced object, which is the
# correct independent oracle input for areas that can actually be assembled.
if ((getid_status > 1)); then
    echo "osmium getid failed with status $getid_status" >&2
    exit "$getid_status"
fi
test -s "$filtered"
echo "getid_status=$getid_status"
echo "recursive_relations=$(osmium fileinfo -e -g data.count.relations "$filtered")"
echo "oracle_stage=export"

if ! osmium export \
    --overwrite \
    --show-errors \
    --geometry-types=polygon \
    --attributes=type,id \
    -f geojson \
    -o "$geojson" \
    "$filtered" \
    2>"$errors"
then
    cat "$errors" >&2
    exit 1
fi

echo "export_features=$(jq '.features | length' "$geojson")"
echo "export_relation_areas=$(jq '[.features[] | select(.properties["@type"] == "relation")] | length' "$geojson")"

jq -r '
    .features[]
    | select(.properties["@type"] == "relation")
    | [
        (.properties["@id"] | tostring),
        (
          if .geometry.type == "Polygon"
          then 1
          elif .geometry.type == "MultiPolygon"
          then (.geometry.coordinates | length)
          else 0
          end
        ),
        (
          if .geometry.type == "Polygon"
          then ((.geometry.coordinates | length) - 1)
          elif .geometry.type == "MultiPolygon"
          then ([.geometry.coordinates[] | ((length) - 1)] | add // 0)
          else 0
          end
        )
      ]
    | @tsv
' "$geojson" | sort -n > "$output"

awk -F '\t' '
    NF != 3 { bad = 1 }
    $1 !~ /^-?[0-9]+$/ { bad = 1 }
    $2 !~ /^[0-9]+$/ { bad = 1 }
    $3 !~ /^[0-9]+$/ { bad = 1 }
    END { exit bad ? 1 : 0 }
' "$output"

echo "reference_rows=$(wc -l < "$output")"
echo "reference_tsv=$output"
echo "osmium_errors=$errors"
