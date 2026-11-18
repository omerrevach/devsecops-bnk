#!/usr/bin/env bash
# make test-lab: the negative tests that need the running lab.
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a
# shellcheck source=/dev/null
. ./lab.env
set +a
export AWS_DEFAULT_REGION="$AWS_REGION"
echo "######## IAM: secret isolation, signing, no privilege escalation"
bash tests/lab/iam-test.sh
echo; echo "######## Cluster: Flux least privilege, database role and TLS, Pod Security"
scripts/ssm-run.sh prod platform/prod/security-test.sh
echo; echo "######## Network: runners have no internet"
scripts/ssm-run.sh -e MODE=check build-runner platform/runner/maintenance.sh
echo; echo "ALL LAB TESTS PASSED"
