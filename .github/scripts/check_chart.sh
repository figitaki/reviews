#!/usr/bin/env bash
# Lints and renders charts/reviews. Run from the repository root.
set -euo pipefail

chart=charts/reviews
prod="$chart/ci/production-values.yaml"

# The chart is released with the server, so its version and appVersion must
# both equal the version in mix.exs.
mix_version="$(sed -n 's/.*version: "\([^"]*\)".*/\1/p' mix.exs | head -n 1)"
chart_version="$(sed -n 's/^version: *//p' "$chart/Chart.yaml")"
app_version="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$chart/Chart.yaml")"
if [ "$chart_version" != "$mix_version" ] || [ "$app_version" != "$mix_version" ]; then
  echo "charts/reviews/Chart.yaml has version $chart_version and appVersion $app_version;" \
    "both must equal the mix.exs version $mix_version." >&2
  exit 1
fi

helm lint --strict "$chart"
helm lint --strict "$chart" -f "$prod"
helm template reviews "$chart" > /dev/null
helm template reviews "$chart" -f "$prod" > /dev/null

# Prints kind/name for every object a render produces.
names() {
  helm template "$@" -f "$prod" --set demo.enabled=true |
    awk '/^kind:/ { kind = $2 } /^  name:/ { print kind "/" $2 }'
}

fail_on_dupes() {
  local dupes
  dupes="$(sort | uniq -d)"
  if [ -n "$dupes" ]; then
    echo "$1" >&2
    echo "$dupes" >&2
    exit 1
  fi
}

# The longest allowed name must not give two objects of one kind one name.
names reviews "$chart" --set fullnameOverride="$(printf 'r%.0s' $(seq 63))" |
  fail_on_dupes "Objects that share a kind and name with a 63-character fullnameOverride:"

# Two long release names that differ only at the end must not collide in one
# namespace, and every name must fit its limit: 63 characters, or 50 for a
# CloudNativePG Cluster.
long="reviews-$(printf 'a%.0s' $(seq 42))"
all="$(names "$long-a" "$chart" --set secrets.existingSecret=; names "$long-b" "$chart" --set secrets.existingSecret=)"
echo "$all" | fail_on_dupes "Objects that two releases in one namespace would share:"
too_long="$(echo "$all" | awk -F/ '{ max = ($1 == "Cluster") ? 50 : 63 } length($2) > max')"
if [ -n "$too_long" ]; then
  echo "Names longer than their limit:" >&2
  echo "$too_long" >&2
  exit 1
fi

echo "Chart checks passed."
