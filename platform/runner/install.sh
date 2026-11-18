#!/bin/bash
# Installs and registers a GitLab runner (Docker executor). Safe to run again.
#
# Run from the laptop (repo root); make up does this for you, in two stages:
#   scripts/ssm-run.sh -e ROLE=build -e STAGE=install  build-runner platform/runner/install.sh
#   scripts/ssm-run.sh -e ROLE=build -e STAGE=register -e PROJECT=bank-lab -e REGION=eu-central-1 \
#     build-runner platform/runner/install.sh platform/harbor/mirror.txt
#
# ROLE=build:   untrusted jobs (merge requests). No AWS permissions, no way to sign.
# ROLE=release: protected jobs on main only. Its IAM role is the only one allowed kms:Sign, and only
#               it lets job containers reach the instance role (IMDS hop limit 2, set in Terraform).
set -euo pipefail

RUNNER_VERSION="19.5.3-1"   # matches GitLab 19.5
ROLE="${ROLE:?ROLE=build or ROLE=release}"
STAGE="${STAGE:-install}"
PROJECT="${PROJECT:-bank-lab}"
LOG="/var/log/runner-install.log"
trap 'echo "FAILED, last lines of ${LOG}:"; tail -n 30 "$LOG" 2>/dev/null' ERR

# shellcheck source=/dev/null
source /etc/profile.d/lab-proxy.sh
export NEEDRESTART_SUSPEND=1 # no "restart services?" noise from apt

if [ "$STAGE" = install ]; then
  echo "== Docker and GitLab Runner ${RUNNER_VERSION}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl unzip >> "$LOG"
  if ! command -v aws >/dev/null; then
    curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscli.zip
    unzip -q -o /tmp/awscli.zip -d /tmp && /tmp/aws/install >> "$LOG"
  fi
  if ! command -v docker >/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io >> "$LOG"
  fi
  # Docker trusts Harbor's certificate (lab CA). The Docker daemon has no proxy: it only talks to Harbor.
  install -d /etc/docker/certs.d/harbor.lab.internal
  cp /etc/lab-ca/ca.crt /etc/docker/certs.d/harbor.lab.internal/ca.crt

  # The helper images package means jobs never pull from registry.gitlab.com.
  if [ ! -f /etc/apt/sources.list.d/runner_gitlab-runner.list ]; then
    curl -fsSL https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | bash >> "$LOG" 2>&1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --allow-change-held-packages \
    "gitlab-runner=${RUNNER_VERSION}" "gitlab-runner-helper-images=${RUNNER_VERSION}" >> "$LOG" 2>&1
  apt-mark hold gitlab-runner gitlab-runner-helper-images >/dev/null
  # Installed but not running: it starts only at STAGE=register, after the installers' window is closed.
  systemctl disable --now gitlab-runner >/dev/null 2>&1 || true
  echo "installed (stopped until registration)"
  exit 0
fi

echo "== Register ${ROLE} runner"
REGION="${REGION:?REGION is required}"
token=$(aws ssm get-parameter --name "/${PROJECT}/gitlab/runner-token-${ROLE}" --with-decryption \
  --query Parameter.Value --output text)

if [ "$ROLE" = release ]; then
  concurrent=1
  default_image="harbor.lab.internal/mirror/sigstore/cosign/cosign:v3.1.4-dev@sha256:8af1a2cf9fba903fdfc6bdafdc25f7b13ef34ad722095543ea787fb96f7240c1"
  environment="environment = [\"AWS_REGION=${REGION}\"]"
  build_options=""
else
  concurrent=2
  default_image="harbor.lab.internal/mirror/library/python:3.13-slim"
  environment=""
  # Buildah builds images inside an unprivileged job container. It needs the unshare syscall (blocked by
  # Docker's default seccomp filter), FUSE mounts (blocked by the default AppArmor profile) and /dev/fuse.
  # Still no privileged mode, no added capabilities, no Docker socket; only this runner, which has no
  # AWS permissions and no internet. See README "Known gaps".
  build_options='security_opt = ["seccomp:unconfined", "apparmor:unconfined"]
    devices = ["/dev/fuse"]'
fi

install -m 600 /dev/null /etc/gitlab-runner/config.toml
cat > /etc/gitlab-runner/config.toml <<EOF
concurrent = ${concurrent}
check_interval = 3

[[runners]]
  name = "${ROLE}-runner"
  url = "https://gitlab.lab.internal"
  token = "${token}"
  executor = "docker"
  tls-ca-file = "/etc/lab-ca/ca.crt"
  ${environment}
  [runners.docker]
    image = "${default_image}"
    privileged = false                        # no privileged containers, no Docker socket
    disable_cache = true
    volumes = ["/etc/lab-ca:/etc/lab-ca:ro"]  # jobs trust the lab CA, read-only
    allowed_images = ["harbor.lab.internal/mirror/**"]
    allowed_pull_policies = ["always", "if-not-present"]
    pull_policy = ["if-not-present"]
    ${build_options}
EOF
unset token
# A running runner reloads config.toml by itself, so jobs in progress are not interrupted.
systemctl enable --now gitlab-runner >/dev/null 2>&1
gitlab-runner verify 2>&1 | grep -E 'is (valid|alive)|ERROR' || true

echo "== Pre-pull the CI images this runner uses (first pipeline does not wait on downloads)"
if [ "$ROLE" = release ]; then
  wanted="sigstore/cosign/cosign alpine/helm"
else
  wanted="aquasec/trivy bridgecrew/checkov library/python buildah/stable alpine/helm gitleaks/gitleaks"
fi
while read -r _ repository tag digest; do
  case " $wanted " in *" $repository "*) ;; *) continue ;; esac
  image="harbor.lab.internal/mirror/${repository}:${tag}"
  [ "$digest" != "-" ] && image="${image}@${digest}" # the exact reference CI uses
  docker pull -q "$image" >> "$LOG"
  echo "pulled ${image}"
done < <(grep -v '^#' /root/bootstrap/mirror.txt)
rm -rf /root/bootstrap
