#!/usr/bin/env bash
# A valid exception lets through ONLY its CVE in its exact package version. With the joblib 1.1.0 exception:
#   joblib==1.1.0           passes (the accepted risk)
#   joblib==1.0.1           fails  (same CVE, another version)
#   joblib==1.1.0 + PyYAML==5.3   fails  (a different Critical, CVE-2020-14343)
# Uses the pinned Trivy image (online DB on the laptop; CI uses the mirrored DB).
set -euo pipefail
cd "$(dirname "$0")/.."
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/exceptions.yaml" <<YAML
vulnerabilities:
  - id: CVE-2022-21797
    purls:
      - "pkg:pypi/joblib@1.1.0"
    expired_at: $(date -u -d '+14 days' +%F)
    statement: "ticket=SEC-101; approved-by=security-lead; reason=test; compensating=test"
YAML
python3 scripts/check_exceptions.py "$work/exceptions.yaml" >/dev/null

gate() { # gate <case dir>: exit code of the CRITICAL gate with the exception file
  docker run --rm -v "$work:/w:ro" -v "${TRIVY_CACHE:-$HOME/.cache/trivy}:/root/.cache/trivy" "$TRIVY_IMAGE" \
    fs -q --scanners vuln --ignorefile /w/exceptions.yaml --severity CRITICAL --exit-code 1 "/w/$1" >/dev/null 2>&1
}
failed=0
check() { # check <name> <requirements> <expected: pass|block>
  mkdir -p "$work/$1" && printf '%s\n' "$2" > "$work/$1/requirements.txt"
  if gate "$1"; then got=pass; else got=block; fi
  if [ "$got" = "$3" ]; then echo "ok   $3: $1"; else echo "FAIL expected $3, got $got: $1"; failed=1; fi
}
check excepted-version "joblib==1.1.0" pass
check other-version "joblib==1.0.1" block
check other-critical "$(printf 'joblib==1.1.0\nPyYAML==5.3')" block
if [ "$failed" != 0 ]; then echo "FAIL: exception scope"; exit 1; fi
echo "PASS: exception scope"
