#!/bin/bash
# shellcheck disable=SC2129 # separate appends to the log keep each step readable
# Installs k3s and Flux on the prod VM and points Flux at Harbor. Safe to run again.
#
# Run from the laptop (repo root); make up does this for you:
#   scripts/ssm-run.sh -e PROJECT=bank-lab prod platform/prod/bootstrap.sh .lab/cosign.pub \
#     platform/flux/bank-app.yaml platform/flux/flux-lockdown.yaml
#
# Before running:
#   - the proxy's bootstrap allowlist is still open (installers are downloaded through it)
#   - Harbor is configured: the mirror holds the Flux images, and the prod-pull robot secret
#     is in Parameter Store at /<project>/harbor/robot-prod-pull (only this VM can read it)
set -euo pipefail

K3S_VERSION="v1.37.2+k3s1"   # https://github.com/k3s-io/k3s/releases
FLUX_VERSION="2.10.0"        # must match the controller images mirrored into Harbor
PROJECT="${PROJECT:-bank-lab}"
HARBOR="harbor.lab.internal"
FILES="/root/bootstrap"      # cosign.pub and bank-app.yaml are unpacked here by ssm-run.sh
LOG="/var/log/prod-bootstrap.log"
trap 'echo "FAILED, last lines of ${LOG}:"; tail -n 30 "$LOG" 2>/dev/null' ERR

# SSM runs a non-login shell: load the proxy settings and region explicitly.
# shellcheck source=/dev/null
source /etc/profile.d/lab-proxy.sh
export NEEDRESTART_SUSPEND=1 # no "restart services?" noise from apt
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "== Packages and AWS CLI"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates openssl unzip >/dev/null
if ! command -v aws >/dev/null; then
  curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscli.zip
  unzip -q -o /tmp/awscli.zip -d /tmp && /tmp/aws/install >/dev/null
fi

# Read with this VM's own IAM role; the secret never appears in the SSM command.
PULL_SECRET=$(aws ssm get-parameter --name "/${PROJECT}/harbor/robot-prod-pull" \
  --with-decryption --query Parameter.Value --output text)

echo "== k3s ${K3S_VERSION} (binary + air-gap images, so it never pulls from Docker Hub)"
url_version="${K3S_VERSION/+/%2B}"
release="https://github.com/k3s-io/k3s/releases/download/${url_version}"
if ! k3s --version 2>/dev/null | grep -qF "${K3S_VERSION}"; then
  curl -fsSLo /usr/local/bin/k3s "${release}/k3s" && chmod 755 /usr/local/bin/k3s
  mkdir -p /var/lib/rancher/k3s/agent/images
  curl -fsSLo /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst \
    "${release}/k3s-airgap-images-amd64.tar.zst"
fi

# containerd pulls only from Harbor, with the pull-only robot account and the lab CA.
install -d -m 755 /etc/rancher/k3s
install -m 600 /dev/null /etc/rancher/k3s/registries.yaml
cat > /etc/rancher/k3s/registries.yaml <<EOF
configs:
  "${HARBOR}":
    auth:
      username: "robot\$prod-pull"
      password: "${PULL_SECRET}"
    tls:
      ca_file: /etc/lab-ca/ca.crt
EOF

if ! systemctl is-active --quiet k3s; then
  curl -fsSLo /root/k3s-install.sh https://get.k3s.io
  # No ingress or load balancer (unused); Secrets encrypted at rest; kubeconfig readable by root only.
  INSTALL_K3S_SKIP_DOWNLOAD=true \
  INSTALL_K3S_EXEC="--disable=traefik --disable=servicelb --secrets-encryption --write-kubeconfig-mode=600" \
    sh /root/k3s-install.sh >> "$LOG" 2>&1
else
  systemctl restart k3s # picks up registries.yaml changes
fi
grep -q KUBECONFIG /root/.bashrc || echo "export KUBECONFIG=${KUBECONFIG}" >> /root/.bashrc
# The node object appears a few seconds after k3s starts; only then can we wait for Ready.
for _ in $(seq 1 60); do kubectl get nodes 2>/dev/null | grep -q . && break; sleep 3; done
kubectl wait --for=condition=Ready node --all --timeout=180s

echo "== Flux ${FLUX_VERSION}: only source-controller and helm-controller, images from Harbor"
if ! flux version --client 2>/dev/null | grep -qF "${FLUX_VERSION}"; then
  curl -fsSLo /tmp/flux.tgz \
    "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_amd64.tar.gz"
  tar xzf /tmp/flux.tgz -C /usr/local/bin flux
fi
flux install --components=source-controller,helm-controller --registry="${HARBOR}/mirror/fluxcd" >> "$LOG" 2>&1
flux check >> "$LOG" 2>&1

# Least privilege (see platform/flux/flux-lockdown.yaml): no cluster-admin for the controllers, releases only
# through an impersonated service account, a no-permission default, no references across namespaces.
kubectl delete clusterrolebinding cluster-reconciler-flux-system --ignore-not-found >> "$LOG"
kubectl apply -f "${FILES}/flux-lockdown.yaml" >> "$LOG"
args=$(kubectl -n flux-system get deployment helm-controller -o jsonpath='{.spec.template.spec.containers[0].args}')
for flag in --default-service-account=flux-no-access --no-cross-namespace-refs=true; do
  case "$args" in *"$flag"*) ;; *)
    kubectl -n flux-system patch deployment helm-controller --type=json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"${flag}\"}]" >> "$LOG" ;;
  esac
done
kubectl -n flux-system rollout status deployment helm-controller --timeout=180s >> "$LOG"
echo "flux controllers ready (no cluster-admin; releases only as bank-app-deployer)"

echo "== Secrets Flux needs (applied, so re-runs update them)"
# shellcheck disable=SC2016 # the robot's name really contains a $
kubectl -n flux-system create secret docker-registry harbor-pull --docker-server="${HARBOR}" \
  --docker-username='robot$prod-pull' --docker-password="${PULL_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n flux-system create secret generic harbor-ca --from-file=ca.crt=/etc/lab-ca/ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n flux-system create secret generic cosign-pub --from-file=cosign.pub="${FILES}/cosign.pub" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "== App namespace, OCIRepository and HelmRelease"
kubectl apply -f "${FILES}/bank-app.yaml"

echo "== Database secrets (created once, inside this cluster only; never in Git, CI or Parameter Store)"
# db-admin: the postgres superuser, mounted only in the database pod. db-credentials: the app's own login.
for secret in db-admin db-credentials; do
  if ! kubectl -n bank-app get secret "$secret" >/dev/null 2>&1; then
    kubectl -n bank-app create secret generic "$secret" \
      --from-literal=password="$(openssl rand -base64 24 | tr -d '/+=')" >> "$LOG"
  fi
done
# TLS for the database: a CA that exists only here, and a server certificate for the database Service.
# The app trusts only this CA and checks the hostname, so it cannot be pointed at another server.
if ! kubectl -n bank-app get secret db-tls >/dev/null 2>&1; then
  pki=$(mktemp -d)
  db=bank-app-postgres
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 825 -subj "/CN=bank-app database CA" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
    -keyout "$pki/ca.key" -out "$pki/ca.crt" 2>> "$LOG"
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=${db}.bank-app.svc.cluster.local" \
    -keyout "$pki/tls.key" -out "$pki/tls.csr" 2>> "$LOG"
  printf 'subjectAltName=DNS:%s,DNS:%s.bank-app,DNS:%s.bank-app.svc,DNS:%s.bank-app.svc.cluster.local\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' \
    "$db" "$db" "$db" "$db" > "$pki/ext"
  openssl x509 -req -in "$pki/tls.csr" -CA "$pki/ca.crt" -CAkey "$pki/ca.key" -CAcreateserial -days 825 \
    -extfile "$pki/ext" -out "$pki/tls.crt" 2>> "$LOG"
  kubectl -n bank-app create secret generic db-ca --from-file=ca.crt="$pki/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f - >> "$LOG"
  kubectl -n bank-app create secret generic db-tls --from-file=tls.crt="$pki/tls.crt" \
    --from-file=tls.key="$pki/tls.key" >> "$LOG"
  rm -rf "$pki" # the CA key is not kept: a new certificate means a new CA
fi

rm -rf "${FILES}"
echo "== Done"
kubectl get nodes
flux get sources oci -A   # "no tags" until the first release - expected
