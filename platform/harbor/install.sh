#!/bin/bash
# Installs Harbor on the harbor VM. Safe to run again.
#
# Run from the laptop (repo root); make up does this for you:
#   scripts/ssm-run.sh -e PROJECT=bank-lab harbor platform/harbor/install.sh
#
# The admin password is generated once and stored in Parameter Store (/<project>/harbor/admin-password).
set -euo pipefail

HARBOR_VERSION="v2.15.5"   # keep in step with platform/harbor/mirror.txt
PROJECT="${PROJECT:-bank-lab}"
LOG="/var/log/harbor-install.log"
trap 'echo "FAILED, last lines of ${LOG}:"; tail -n 30 "$LOG" 2>/dev/null' ERR

# SSM runs a non-login shell: load the proxy settings and region explicitly.
# shellcheck source=/dev/null
source /etc/profile.d/lab-proxy.sh
export NEEDRESTART_SUSPEND=1 # no "restart services?" noise from apt

echo "== Packages, AWS CLI, Docker"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl jq unzip openssl python3-yaml >> "$LOG"
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
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >> "$LOG"
fi

echo "== TLS certificate and key from Parameter Store"
param() { aws ssm get-parameter --name "/${PROJECT}/pki/harbor/$1" --with-decryption --query Parameter.Value --output text; }
install -d -m 700 /etc/harbor-tls
install -m 600 /dev/null /etc/harbor-tls/harbor.key
install -m 600 /dev/null /etc/harbor-tls/harbor.crt
param key  > /etc/harbor-tls/harbor.key
param cert > /etc/harbor-tls/harbor.crt

if curl -fsS --cacert /etc/lab-ca/ca.crt --resolve harbor.lab.internal:443:127.0.0.1 \
  https://harbor.lab.internal/api/v2.0/ping >/dev/null 2>&1; then
  echo "== Harbor already running"
  exit 0
fi

echo "== Harbor ${HARBOR_VERSION} offline installer"
if [ ! -d /opt/harbor ]; then
  curl -fsSL -o /tmp/harbor.tgz \
    "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-offline-installer-${HARBOR_VERSION}.tgz"
  tar xzf /tmp/harbor.tgz -C /opt && rm /tmp/harbor.tgz
fi

# Admin password: generated once, kept root-only on the VM and in Parameter Store for the admin.
if [ ! -f /root/harbor-admin-password ]; then
  install -m 600 /dev/null /root/harbor-admin-password
  openssl rand -base64 24 | tr -d '/+=' > /root/harbor-admin-password
fi
aws ssm put-parameter --name "/${PROJECT}/harbor/admin-password" --type SecureString --key-id "alias/${PROJECT}-secrets" --overwrite \
  --value "$(cat /root/harbor-admin-password)" > /dev/null

python3 - <<'PY'
import secrets, yaml
c = yaml.safe_load(open("/opt/harbor/harbor.yml.tmpl"))
c["hostname"] = "harbor.lab.internal"
c["https"].update({"port": 443,
                   "certificate": "/etc/harbor-tls/harbor.crt",
                   "private_key": "/etc/harbor-tls/harbor.key"})
c["harbor_admin_password"] = open("/root/harbor-admin-password").read().strip()
c["database"]["password"] = secrets.token_urlsafe(24)
c["data_volume"] = "/data"
# Only replication (core + jobservice) goes out, and only through the egress proxy.
c["proxy"] = {
    "http_proxy": "http://proxy.lab.internal:3128",
    "https_proxy": "http://proxy.lab.internal:3128",
    "no_proxy": "127.0.0.1,localhost,.local,.internal,core,jobservice,registry,registryctl,portal,postgresql,redis,log,exporter",
    "components": ["core", "jobservice"],
}
yaml.safe_dump(c, open("/opt/harbor/harbor.yml", "w"), sort_keys=False)
PY
chmod 600 /opt/harbor/harbor.yml

# No --with-trivy: scanning happens in CI.
(cd /opt/harbor && ./install.sh) >> "$LOG" 2>&1

for _ in $(seq 1 60); do
  if curl -fsS --cacert /etc/lab-ca/ca.crt --resolve harbor.lab.internal:443:127.0.0.1 \
    https://harbor.lab.internal/api/v2.0/ping >/dev/null 2>&1; then
    echo "== Harbor is up"
    exit 0
  fi
  sleep 5
done
echo "Harbor did not answer within 5 minutes" >&2
exit 1
