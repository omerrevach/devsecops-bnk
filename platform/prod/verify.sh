#!/bin/bash
# Verify that prod runs EXACTLY the expected release: signature verified, that chart version installed,
# that image digest running, rollout complete, /healthz = HTTP 200 {"status": "ok"}.
#
#   scripts/ssm-run.sh -e EXPECTED_VERSION=1.0.42 -e EXPECTED_DIGEST=sha256:... prod platform/prod/verify.sh \
#     platform/prod/verify_release.py
# Without EXPECTED_VERSION it only shows the current state (make status) and claims nothing.
# Waits up to 10 minutes for Flux; prints HEALTHY on the last line only when every check passes.
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
CHECKER=/root/bootstrap/verify_release.py

show() {
  echo "Flux source (Flux verifies the cosign signature before using a chart):"
  flux get sources oci -A --no-header | awk '{ $1 = ""; print "  " $0 }'
  echo "  SourceVerified=$(kubectl -n flux-system get ocirepository bank-app \
    -o jsonpath='{.status.conditions[?(@.type=="SourceVerified")].status}')"
  echo "HelmRelease:"
  flux get helmreleases -A --no-header | awk '{ $1 = ""; print "  " $0 }'
  echo "Pods in bank-app:"
  kubectl -n bank-app get pods --no-headers 2>/dev/null | awk '{ print "  " $1, $2, $3 }'
}

if [ -z "${EXPECTED_VERSION:-}" ]; then
  show
  echo "(status only: run with EXPECTED_VERSION and EXPECTED_DIGEST to verify a release)"
  exit 0
fi
EXPECTED_DIGEST="${EXPECTED_DIGEST:?EXPECTED_DIGEST is required with EXPECTED_VERSION}"

work=$(mktemp -d)
forward=""
cleanup() {
  [ -n "$forward" ] && kill "$forward" 2>/dev/null
  rm -rf "$work" /root/bootstrap
}
trap cleanup EXIT

collect() {
  local code body
  code=000
  body=""
  kubectl -n bank-app port-forward svc/bank-app 18080:8080 >/dev/null 2>&1 &
  forward=$!
  sleep 2
  body=$(curl -s -m 5 -o - -w '\n%{http_code}' localhost:18080/healthz 2>/dev/null) || true
  kill "$forward" 2>/dev/null || true
  forward=""
  code=$(echo "$body" | tail -n 1)
  body=$(echo "$body" | sed '$d')
  python3 - "$work/state.json" "$code" "$body" \
    <(kubectl -n flux-system get ocirepository bank-app -o json 2>/dev/null) \
    <(kubectl -n flux-system get helmrelease bank-app -o json 2>/dev/null) \
    <(kubectl -n bank-app get deployment bank-app -o json 2>/dev/null || echo '{}') <<'PY'
import json, sys
out, code, body, oci, hr, dep = sys.argv[1:7]
def load(path):  # a missing object is an empty one: its checks fail instead of crashing
    try:
        return json.loads(open(path).read() or "{}")
    except ValueError:
        return {}
state = {"ocirepository": load(oci), "helmrelease": load(hr), "deployment": load(dep),
         "health": {"code": int(code) if code.isdigit() else 0, "body": body}}
json.dump(state, open(out, "w"))
PY
}

# Ask Flux to look now: after failing while no release existed, it backs off and could take many minutes.
for object in ocirepository/bank-app helmrelease/bank-app; do
  kubectl -n flux-system annotate --overwrite "$object" reconcile.fluxcd.io/requestedAt="$(date +%s)" >/dev/null
done
deadline=$(($(date +%s) + 600))
while :; do
  collect
  if python3 "$CHECKER" "$work/state.json" "$EXPECTED_VERSION" "$EXPECTED_DIGEST" > "$work/result" 2>&1; then
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "Release ${EXPECTED_VERSION} not verified within 10 minutes:"
    cat "$work/result"
    show
    exit 1
  fi
  sleep 15
done
echo "Release ${EXPECTED_VERSION} (${EXPECTED_DIGEST}):"
cat "$work/result"
show
echo HEALTHY
