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

filtered="$tmp/multipolygons.osm.pbf"
geojson="$tmp/multipolygons.geojson"
errors="\${output%.tsv}.osmium-errors.txt"

osmium tags-filter \
    --overwrite \
    -o "$filtered" \
    "$input" \
    r/type=multipolygon

osmium export \
    --overwrite \
    --show-errors \
    --geometry-types=polygon \
    --attributes=type,id \
    -f geojson \
    -o "$geojson" \
    "$filtered" \
    2>"$errors"

jq -r '
    .features[]
    | select(
        .properties["@type"] == "relation"
        and .properties.type == "multipolygon"
      )
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
