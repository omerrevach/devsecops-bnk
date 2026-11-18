#!/bin/bash
# Imports the repository (sent as a git bundle) into bank/bank as security-lead. Safe to run again.
#
# make up runs it with: scripts/ssm-run.sh -e PROJECT=bank-lab gitlab platform/gitlab/push.sh .lab/repo.bundle
#
# The import is done by a Maintainer (Security): developers can neither push to main nor run pipelines
# on it. After the import, main changes only through merge requests, so later runs leave it alone.
set -euo pipefail

PROJECT="${PROJECT:-bank-lab}"
REMOTE="https://gitlab.lab.internal/bank/bank.git"

# shellcheck source=/dev/null
source /etc/profile.d/lab-proxy.sh

token=$(aws ssm get-parameter --name "/${PROJECT}/gitlab/token-security-lead" --with-decryption \
  --query Parameter.Value --output text)
auth="Authorization: Basic $(printf 'security-lead:%s' "$token" | base64 -w0)"
# GitLab on this VM, by its real name (TLS matches); the load balancer is for other machines.
git_remote() {
  git -c http.sslCAInfo=/etc/lab-ca/ca.crt -c http.curloptResolve=gitlab.lab.internal:443:127.0.0.1 \
    -c http.extraHeader="$auth" "$@"
}

if git_remote ls-remote --exit-code --heads "$REMOTE" main >/dev/null 2>&1; then
  echo "bank/bank already has main; nothing pushed (main only changes through merge requests)"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work" /root/bootstrap' EXIT
git clone --quiet --branch main /root/bootstrap/repo.bundle "$work/repo"
cd "$work/repo"
git_remote push --quiet "$REMOTE" HEAD:refs/heads/main
echo "pushed $(git rev-parse --short HEAD) to bank/bank main: the first pipeline is running"
