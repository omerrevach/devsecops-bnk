#!/bin/sh
# Print the image (repository@digest) a chart value block deploys, e.g. "postgres", from the chart's values.
# Used by CI so every workload image in the release is scanned, not only the app image.
set -eu
BLOCK="${1:?usage: chart-image.sh <values block, e.g. postgres>}"
VALUES="${2:-charts/bank-app/values.yaml}"
awk -v block="$BLOCK" '
  $0 ~ "^" block ":" { inside = 1; next }
  inside && /^[^ #]/ { inside = 0 }
  inside && $1 == "repository:" { repo = $2 }
  inside && $1 == "digest:" { gsub(/"/, "", $2); digest = $2 }
  END {
    if (repo == "" || digest !~ /^sha256:[a-f0-9]{64}$/) { print "no pinned image in block " block > "/dev/stderr"; exit 1 }
    print repo "@" digest
  }' "$VALUES"
