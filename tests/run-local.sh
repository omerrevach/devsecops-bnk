#!/usr/bin/env bash
# make test: every local negative test (no AWS needed; Docker for the image-based ones).
set -euo pipefail
cd "$(dirname "$0")/.."
run() { echo; echo "######## $1"; shift; "$@"; }
run "exception validator" python3 tests/exceptions-test.py
run "exception scope (Trivy)" bash tests/exception-scope-test.sh
run "feed freshness boundaries" sh tests/feed-check-test.sh
run "release verifier" python3 tests/verify-test.py
run "IaC gate (weakened chart, exact CI Checkov image)" bash tests/iac-test.sh
run "Terraform preflight blocks apply" bash tests/preflight-test.sh
run "database role and TLS" bash tests/db-test.sh
echo; echo "ALL LOCAL TESTS PASSED"
