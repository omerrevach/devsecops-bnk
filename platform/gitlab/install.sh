#!/bin/bash
# Installs GitLab on the gitlab VM. Safe to run again.
#
# Run it from the laptop (repo root), Phase 5:
#   scripts/ssm-run.sh gitlab platform/gitlab/install.sh platform/gitlab/gitlab.rb
#
# Before running: the proxy's bootstrap allowlist is still open (packages come through it).
# Afterwards: read the first root password in an SSM session (not here, SSM keeps command output):
#   vm gitlab;  sudo cat /etc/gitlab/initial_root_password
set -euo pipefail

GITLAB_VERSION="19.5.6-ee.0"   # apt-cache madison gitlab-ee
PROJECT="${PROJECT:-bank-lab}"
FILES="/root/bootstrap"        # gitlab.rb is unpacked here by ssm-run.sh
LOG="/var/log/gitlab-install.log"
trap 'echo "FAILED, last lines of ${LOG}:"; tail -n 30 "$LOG" 2>/dev/null' ERR

# SSM runs a non-login shell: load the proxy settings and region explicitly.
# shellcheck source=/dev/null
source /etc/profile.d/lab-proxy.sh
export NEEDRESTART_SUSPEND=1 # no "restart services?" noise from apt

echo "== Packages and AWS CLI"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates unzip jq python3-pip >/dev/null
if ! command -v aws >/dev/null; then
  curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscli.zip
  unzip -q -o /tmp/awscli.zip -d /tmp && /tmp/aws/install
fi

echo "== Swap (GitLab needs more than the VM's 8 GB during upgrades and reconfigures)"
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
swapon --show | grep -q /swapfile || swapon /swapfile

echo "== TLS certificate and key from Parameter Store (read with this VM's own IAM role)"
param() { aws ssm get-parameter --name "/${PROJECT}/pki/gitlab/$1" --with-decryption --query Parameter.Value --output text; }
install -d -m 700 /etc/gitlab/ssl
install -m 600 /dev/null /etc/gitlab/ssl/gitlab.lab.internal.key
install -m 600 /dev/null /etc/gitlab/ssl/gitlab.lab.internal.crt
param key  > /etc/gitlab/ssl/gitlab.lab.internal.key
param cert > /etc/gitlab/ssl/gitlab.lab.internal.crt

# Config goes in before the package, so the first reconfigure already uses it
# (no Let's Encrypt attempt, no container registry).
install -m 600 "${FILES}/gitlab.rb" /etc/gitlab/gitlab.rb

echo "== GitLab ${GITLAB_VERSION} (output in ${LOG})"
if [ ! -f /etc/apt/sources.list.d/gitlab_gitlab-ee.list ]; then
  curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ee/script.deb.sh | bash >> "$LOG" 2>&1
fi
if dpkg-query -W -f='${Version}' gitlab-ee 2>/dev/null | grep -qxF "$GITLAB_VERSION"; then
  gitlab-ctl reconfigure >> "$LOG" 2>&1   # already installed: just apply gitlab.rb
else
  DEBIAN_FRONTEND=noninteractive apt-get install -y "gitlab-ee=${GITLAB_VERSION}" >> "$LOG" 2>&1
fi
apt-mark hold gitlab-ee >/dev/null    # upgrades are deliberate, never a side effect of apt upgrade

rm -rf "$FILES"
gitlab-ctl status
