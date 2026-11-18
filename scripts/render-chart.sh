#!/bin/sh
# Lint the Helm chart and render it to plain YAML, so Checkov scans exactly what would be deployed.
# Usage: render-chart.sh [output_dir]       (default: rendered/)
# The app image digest is a placeholder here; CI sets the real one when it packages a release.
set -eu

CHART=charts/bank-app
OUT_DIR="${1:-rendered}"
PLACEHOLDER_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"

helm lint --strict "$CHART" --set image.digest="$PLACEHOLDER_DIGEST"

mkdir -p "$OUT_DIR"
helm template bank-app "$CHART" \
  --namespace bank-app \
  --set image.digest="$PLACEHOLDER_DIGEST" \
  > "$OUT_DIR/bank-app.yaml"

echo "Rendered $CHART to $OUT_DIR/bank-app.yaml"
