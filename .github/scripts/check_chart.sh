#!/usr/bin/env bash
# Lints and renders charts/reviews. Run from the repository root.
set -euo pipefail

chart=charts/reviews
prod="$chart/ci/production-values.yaml"

helm lint --strict "$chart"
helm lint --strict "$chart" -f "$prod"
helm template reviews "$chart" > /dev/null
helm template reviews "$chart" -f "$prod" > /dev/null

# The longest allowed name must not make two objects of one kind share a name.
long_name="$(printf 'r%.0s' $(seq 63))"
dupes="$(
  helm template reviews "$chart" -f "$prod" --set demo.enabled=true --set fullnameOverride="$long_name" |
    awk '/^kind:/ { kind = $2 } /^  name:/ { print kind "/" $2 }' |
    sort | uniq -d
)"
if [ -n "$dupes" ]; then
  echo "Objects with the same kind and name for a 63-character fullnameOverride:" >&2
  echo "$dupes" >&2
  exit 1
fi

echo "Chart checks passed."
