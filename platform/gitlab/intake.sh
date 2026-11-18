#!/bin/bash
# Python package intake: the only way a package enters the air-gapped build zone. Safe to run again.
#
# Run from the laptop (repo root); make up does this for you:
#   scripts/ssm-run.sh -e PROJECT=bank-lab gitlab platform/gitlab/intake.sh app/requirements.txt
#
# Downloads exactly the wheels pinned in requirements.txt (every file checked against its hash) through
# the egress proxy, then uploads them to the project's internal PyPI registry in GitLab. CI installs
# only from there, with --require-hashes, so an altered or unlisted package cannot get in.
set -euo pipefail

PROJECT="${PROJECT:-bank-lab}"
GITLAB="https://gitlab.lab.internal"

# shellcheck source=/dev/null
source /etc/profile.d/lab-proxy.sh
export NEEDRESTART_SUSPEND=1

if ! command -v pip3 >/dev/null || ! command -v jq >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-pip jq >/dev/null
fi

wheels=$(mktemp -d)
trap 'rm -rf "$wheels" /root/bootstrap' EXIT
# Wheels for the build image (CPython 3.13, Linux x86_64), never source packages.
pip3 download --quiet --no-deps --require-hashes --only-binary=:all: \
  --python-version 3.13 --platform manylinux2014_x86_64 --implementation cp --abi cp313 \
  -r /root/bootstrap/requirements.txt -d "$wheels"

token=$(aws ssm get-parameter --name "/${PROJECT}/gitlab/token-omeriko" --with-decryption \
  --query Parameter.Value --output text)
# GitLab on this VM, by its real name (TLS matches); the load balancer is for other machines.
api() { curl -fsS --cacert /etc/lab-ca/ca.crt --resolve gitlab.lab.internal:443:127.0.0.1 -H "PRIVATE-TOKEN: ${token}" "$@"; }
project_id=$(api "${GITLAB}/api/v4/projects/bank%2Fbank" | jq -r .id)

for wheel in "$wheels"/*.whl; do
  file=$(basename "$wheel")
  name=$(echo "$file" | cut -d- -f1)
  version=$(echo "$file" | cut -d- -f2)
  if api "${GITLAB}/api/v4/projects/${project_id}/packages?package_type=pypi&package_name=${name}" \
    | jq -e --arg v "$version" '.[] | select(.version == $v)' >/dev/null; then
    echo "already in registry: ${file}"
    continue
  fi
  api -o /dev/null "${GITLAB}/api/v4/projects/${project_id}/packages/pypi" \
    -F "content=@${wheel}" -F "name=${name}" -F "version=${version}" \
    -F "sha256_digest=$(sha256sum "$wheel" | cut -d' ' -f1)"
  echo "uploaded: ${file}"
done
