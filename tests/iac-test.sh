#!/usr/bin/env bash
# The IaC gate, run exactly as CI runs it: same Checkov image (by digest), same script, same paths.
#   unchanged chart and Terraform: pass
#   readOnlyRootFilesystem: false in the app OR the database: iac-k8s fails (CKV_K8S_22)
#   a scan that sees no files: fails (zero coverage), instead of passing silently
set -euo pipefail
cd "$(dirname "$0")/.."
CHECKOV_IMAGE="${CHECKOV_IMAGE:-bridgecrew/checkov:3.4.5@sha256:122602cf32cc72286155d39f1f234b7b594818f7b8d7fdf490701620e521368b}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gate() { # gate <dir with the repo files> <framework> <paths...>
  local dir="$1"
  shift
  docker run --rm -v "$dir:/w" -w /w --entrypoint sh "$CHECKOV_IMAGE" scripts/iac-scan.sh "$1" report "${@:2}" 2>&1 | tail -n 2
}
failed=0
check() { # check <name> <expected pass|fail> <dir> <framework> <paths...>
  local name="$1" want="$2" out
  shift 2
  out=$(gate "$@") || true # a failing gate is an expected outcome here
  if echo "$out" | grep -q '^FAIL'; then got=fail; else got=pass; fi
  if [ "$got" = "$want" ]; then echo "ok   $want: $name ($(echo "$out" | grep -E 'resources' | head -1))"
  else echo "FAIL expected $want, got $got: $name"; echo "$out"; failed=1; fi
}
copy() { mkdir -p "$1" && cp -r .checkov.yaml scripts platform terraform "$1/" && sh scripts/render-chart.sh "$1/rendered" >/dev/null; }

copy "$work/clean"
check "Terraform, unchanged" pass "$work/clean" terraform terraform
check "rendered chart + Flux config, unchanged" pass "$work/clean" kubernetes rendered platform/flux
for kind in Deployment StatefulSet; do
  copy "$work/$kind"
  python3 - "$work/$kind/rendered/bank-app.yaml" "$kind" <<'PY'
import sys, yaml
path, kind = sys.argv[1], sys.argv[2]
docs = list(yaml.safe_load_all(open(path)))
for d in docs:
    if d and d["kind"] == kind:
        d["spec"]["template"]["spec"]["containers"][0]["securityContext"]["readOnlyRootFilesystem"] = False
yaml.safe_dump_all(docs, open(path, "w"))
PY
  check "$kind weakened: readOnlyRootFilesystem false" fail "$work/$kind" kubernetes rendered platform/flux
done
mkdir -p "$work/empty/nothing" && cp -r .checkov.yaml scripts "$work/empty/"
check "scan that finds no files" fail "$work/empty" kubernetes nothing
if [ "$failed" != 0 ]; then echo "FAIL: IaC gate"; exit 1; fi
echo "PASS: IaC gate"
