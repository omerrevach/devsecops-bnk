#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in --query strings are JMESPath, not shell
# The lab in one command. Called by the Makefile:
#   make up         build everything (or finish/repair a lab that exists), then run the demo
#   make demo       only the demo: CVE blocks -> exception MR -> approval -> signed release -> deployed
#   make demo-reset fresh GitLab project bank/bank with the code re-imported, to run the demo again
#   make passwords  print the GitLab and Harbor logins
#   make vpn        write the Client VPN profile (bank-lab.ovpn) for the web UIs
#   make status     show the VMs and what Flux has deployed
#   make down       delete the lab (keeps the Terraform state bucket)
#
# Settings come from lab.env. Every step is safe to run again. Logs: .lab/logs/
set -euo pipefail
cd "$(dirname "$0")/.."

LAB=".lab"
LOGS="${LAB}/logs"
VMS="proxy gitlab harbor build-runner release-runner prod"
START=$(date +%s)

# ------------------------------------------------------------------ helpers
say() { printf '[%02d:%02d] %s\n' $((($(date +%s) - START) / 60)) $((($(date +%s) - START) % 60)) "$*"; }
die() {
  say "FAILED: $*"
  exit 1
}

load_settings() {
  if [ ! -f lab.env ]; then
    echo "lab.env is missing. Create it and adjust the values:  cp lab.env.example lab.env" >&2
    exit 1
  fi
  local demo_override="${DEMO:-}" # make up DEMO=auto overrides lab.env for one run
  set -a
  # shellcheck source=/dev/null
  . ./lab.env
  set +a
  [ -z "$demo_override" ] || DEMO="$demo_override"
  export AWS_DEFAULT_REGION="$AWS_REGION"
  export TF_VAR_project="$PROJECT" TF_VAR_region="$AWS_REGION"
  export TF_VAR_enable_client_vpn="${ENABLE_CLIENT_VPN:-true}"
  # The load balancer keeps deletion protection (Terraform default true); only make down lifts it, right
  # before destroying. Not exported here: Checkov reads TF_VAR_* as text, and "true" would fail its check.
  export TF_IN_AUTOMATION=1
  DEMO="${DEMO:-auto}"
  mkdir -p "$LOGS"
}

# Run a script on a VM (see scripts/ssm-run.sh); output is appended to .lab/logs/<log>.log.
remote() {
  local log="$1"
  shift
  scripts/ssm-run.sh -e "PROJECT=${PROJECT}" -e "REGION=${AWS_REGION}" "$@" >> "${LOGS}/${log}.log" 2>&1
}

# Run steps in parallel: start NAME COMMAND...; then finish waits for all of them.
names=()
pids=()
start() {
  local name="$1"
  shift
  "$@" &
  names+=("$name")
  pids+=($!)
}
finish() {
  local i failed=""
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
      say "  ok      ${names[$i]}"
    else
      say "  FAILED  ${names[$i]}  (last lines of ${LOGS}/${names[$i]}.log:)"
      tail -n 15 "${LOGS}/${names[$i]}.log" 2>/dev/null | sed 's/^/          /'
      failed=1
    fi
  done
  names=()
  pids=()
  [ -z "$failed" ] || die "see the log above"
}

instance_id() {
  aws ec2 describe-instances --filters "Name=tag:Name,Values=${PROJECT}-$1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

# ------------------------------------------------------------------ steps
preflight() {
  local tool
  for tool in aws terraform jq git openssl; do
    command -v "$tool" >/dev/null || die "'$tool' is not installed (see README: Requirements)"
  done
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text) ||
    die "AWS credentials for profile '${AWS_PROFILE}' do not work"
  say "AWS account ${ACCOUNT}, region ${AWS_REGION}, prefix ${PROJECT}"
  if [ -n "$(git status --porcelain)" ]; then
    say "note: uncommitted changes are not deployed; the lab gets the last commit"
  fi
}

# The infrastructure code is checked BEFORE anything changes in AWS: format, validation and the same Checkov
# gate CI uses. If any of it fails, make up stops here and terraform apply never runs.
iac_preflight() {
  say "Preflight: checking the Terraform code before changing anything in AWS"
  command -v checkov >/dev/null || die "'checkov' is not installed (README: Run it)"
  local dir
  for dir in terraform terraform/bootstrap; do
    terraform -chdir="$dir" fmt -recursive -check >> "${LOGS}/preflight.log" 2>&1 ||
      die "terraform fmt: $dir is not formatted (see ${LOGS}/preflight.log)"
    terraform -chdir="$dir" init -backend=false -input=false >> "${LOGS}/preflight.log" 2>&1 ||
      die "terraform init failed in $dir (see ${LOGS}/preflight.log)"
    terraform -chdir="$dir" validate -no-color >> "${LOGS}/preflight.log" 2>&1 ||
      die "terraform validate failed in $dir (see ${LOGS}/preflight.log)"
  done
  sh scripts/iac-scan.sh terraform "${LAB}/iac-terraform" terraform >> "${LOGS}/preflight.log" 2>&1 ||
    die "Terraform security scan failed, nothing was applied (see ${LOGS}/preflight.log)"
  tail -n 1 "${LOGS}/preflight.log" | sed 's/^/          /'
}

state_bucket() {
  say "Terraform state bucket"
  terraform -chdir=terraform/bootstrap init -input=false > "${LOGS}/state.log" 2>&1
  terraform -chdir=terraform/bootstrap apply -input=false -auto-approve >> "${LOGS}/state.log" 2>&1 ||
    die "state bucket (see ${LOGS}/state.log)"
  terraform -chdir=terraform/bootstrap output -raw backend_hcl > terraform/backend.hcl
  terraform -chdir=terraform init -input=false -reconfigure -backend-config=backend.hcl >> "${LOGS}/state.log" 2>&1 ||
    die "terraform init (see ${LOGS}/state.log)"
  # The installers' allowlist, written to the proxy at the start of setup (and emptied at the end).
  echo 'jsonencode(var.bootstrap_domains)' | terraform -chdir=terraform console | jq -r 'fromjson[]' \
    > "${LAB}/bootstrap-domains.txt"
  echo 'jsonencode(var.harbor_feed_domains)' | terraform -chdir=terraform console | jq -r 'fromjson[]' \
    > "${LAB}/harbor-feed-domains.txt"
}

# terraform apply runs in the background: the VMs exist after ~2 minutes, the Client VPN takes ~10.
# Setup starts on the VMs as soon as they answer, while Terraform is still working.
apply_infrastructure() {

  # Apply exactly the plan that was just made from the checked code.
  for _ in 1 2 3; do
    if terraform -chdir=terraform plan -input=false -out "${PWD}/${LAB}/tfplan" >> "${LOGS}/terraform.log" 2>&1 &&
      terraform -chdir=terraform apply -input=false "${PWD}/${LAB}/tfplan" >> "${LOGS}/terraform.log" 2>&1; then
      return 0
    fi
    # A brand-new AWS account can refuse EC2 launches for a few minutes ("PendingVerification").
    grep -q PendingVerification "${LOGS}/terraform.log" || return 1
    sleep 60
  done
  return 1
}

wait_for_vms() {
  local vm deadline=$(($(date +%s) + 1200)) online ids
  say "Waiting for the 6 VMs to come up and register with SSM"
  while :; do
    ids=""
    for vm in $VMS; do ids="$ids $(instance_id "$vm")"; done
    # shellcheck disable=SC2086 # word splitting is intended
    online=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$(echo $ids | tr ' ' ',')" \
      --query 'length(InstanceInformationList[?PingStatus==`Online`])' --output text 2>/dev/null || echo 0)
    [ "$online" = 6 ] && break
    [ "$(cat "${LAB}/terraform.exit" 2>/dev/null)" != 1 ] || die "terraform apply (see ${LOGS}/terraform.log)"
    [ "$(date +%s)" -lt "$deadline" ] || die "VMs did not register with SSM within 20 minutes"
    sleep 10
  done
  printf '#!/bin/bash\ncloud-init status --wait >/dev/null 2>&1 || true\n' > "${LAB}/cloud-init-wait.sh"
  for vm in $VMS; do start "boot-${vm}" remote "boot-${vm}" "$vm" "${LAB}/cloud-init-wait.sh"; done
  finish
}

cosign_public_key() {
  aws kms get-public-key --key-id "alias/${PROJECT}-release-signing" --query PublicKey --output text |
    openssl base64 -d -A | openssl pkey -pubin -inform DER -outform PEM > "${LAB}/cosign.pub"
}

# The lab's GitLab gets one import commit (this repo's last commit, without history: fast over SSM),
# plus one commit that pins the base images to the exact digests now in Harbor's mirror.
prepare_repository() {
  local work digest
  work=$(mktemp -d)
  git archive HEAD | tar -x -C "$work"
  (
    cd "$work"
    git init -q -b main
    git -c user.name="Lab import" -c user.email="lab@lab.internal" add -A
    git -c user.name="Lab import" -c user.email="lab@lab.internal" commit -q \
      -m "Import bank-health-svc $(git -C "$OLDPWD" rev-parse --short HEAD)"
  )
  image_digest() { awk -v i="$1" '$1 == "DIGEST" && $2 == i { print $3 }' "${LAB}/digests.txt" | tail -n 1; }
  python=$(image_digest library/python:3.13-slim)
  distroless=$(image_digest distroless/python3-debian13:nonroot)
  postgres=$(image_digest chainguard/postgres:latest)
  for digest in "$python" "$distroless" "$postgres"; do
    case "$digest" in sha256:*) ;; *) die "base image digests missing from ${LAB}/digests.txt (run make up)" ;; esac
  done
  # First <digest> in the Dockerfile is the build stage (python), the second the runtime (distroless).
  awk -v a="$python" -v b="$distroless" '/@sha256:<digest>/ { n++; sub(/<digest>/, n == 1 ? substr(a, 8) : substr(b, 8)) } 1' \
    "$work/app/Dockerfile" > "$work/Dockerfile.new" && mv "$work/Dockerfile.new" "$work/app/Dockerfile"
  sed -e "s/sha256:1111111111111111111111111111111111111111111111111111111111111111/${postgres}/" \
    "$work/charts/bank-app/values.yaml" > "$work/values.new" && mv "$work/values.new" "$work/charts/bank-app/values.yaml"
  (
    cd "$work"
    git -c user.name="Lab import" -c user.email="lab@lab.internal" commit -q -am \
      "Pin base images to their Harbor mirror digests"
    git bundle create -q repo.bundle main
  )
  mv "$work/repo.bundle" "${LAB}/repo.bundle"
  rm -rf "$work"
}

# Steps that run one after the other on the same VM, in the background next to other VMs' steps.
harbor_setup() {
  remote harbor harbor platform/harbor/install.sh &&
    remote harbor harbor platform/harbor/configure.sh platform/harbor/mirror.txt
}
gitlab_setup() {
  remote gitlab-setup gitlab platform/gitlab/configure.sh platform/gitlab/configure.rb &&
    remote gitlab-setup gitlab platform/gitlab/intake.sh app/requirements.txt
}
wait_for_terraform() {
  while [ ! -s "${LAB}/terraform.exit" ]; do sleep 5; done
  [ "$(cat "${LAB}/terraform.exit")" = 0 ] || die "terraform apply (see ${LOGS}/terraform.log)"
}

# ---- Installer access is a maintenance window. While it is open, no CI job can run: the runners are stopped
# first, and started again only after the window is closed AND the denial is verified. The window closes on
# success and on failure (trap), and the proxy closes it by itself after 60 minutes if this laptop vanishes.
WINDOW_OPEN=""
stop_runners() {
  local vm
  for vm in build-runner release-runner; do
    start "stop-${vm}" remote "stop-${vm}" -e MODE=stop "$vm" platform/runner/maintenance.sh
  done
  finish
}
open_window() {
  stop_runners
  say "Opening the installers' allowlist (runners stopped; closes by itself after 60 min at the latest)"
  WINDOW_OPEN=1
  remote proxy-open -e MODE=open proxy platform/proxy/allowlist.sh "${LAB}/bootstrap-domains.txt" \
    "${LAB}/harbor-feed-domains.txt" || die "proxy allowlist (see ${LOGS}/proxy-open.log)"
}
close_window() {
  say "Closing the installers' allowlist: from now on only Harbor's mirroring reaches the internet"
  remote proxy-close -e MODE=close proxy platform/proxy/allowlist.sh "${LAB}/harbor-feed-domains.txt" ||
    die "closing the allowlist failed (see ${LOGS}/proxy-close.log); runners stay stopped"
  WINDOW_OPEN=""
  local vm
  for vm in build-runner release-runner; do
    start "egress-${vm}" remote "egress-${vm}" -e MODE=check "$vm" platform/runner/maintenance.sh
  done
  finish
  say "Verified: the runners have no internet, neither directly nor through the proxy"
}
close_on_exit() {
  if [ -n "$WINDOW_OPEN" ]; then
    echo "Closing the installers' allowlist after a failure (runners stay stopped until make up succeeds)."
    remote proxy-close -e MODE=close proxy platform/proxy/allowlist.sh || true
  fi
}
trap close_on_exit EXIT

up() {
  load_settings
  rm -f "${LOGS}"/*.log "${LAB}/terraform.exit"
  preflight
  iac_preflight
  state_bucket

  say "terraform apply (log: ${LOGS}/terraform.log)"
  (
    status=0
    apply_infrastructure || status=1
    echo "$status" > "${LAB}/terraform.exit"
  ) &
  wait_for_vms

  open_window

  say "Installing GitLab, Harbor (+ mirroring the CI images) and both runners, in parallel (~10 min)"
  start gitlab-install remote gitlab-install gitlab platform/gitlab/install.sh platform/gitlab/gitlab.rb
  start harbor harbor_setup
  start build-runner-install remote build-runner-install -e ROLE=build -e STAGE=install \
    build-runner platform/runner/install.sh
  start release-runner-install remote release-runner-install -e ROLE=release -e STAGE=install \
    release-runner platform/runner/install.sh
  finish
  grep '^DIGEST' "${LOGS}/harbor.log" > "${LAB}/digests.txt"

  say "Waiting for terraform apply to finish (load balancer, DNS, VPN)"
  wait_for_terraform
  cosign_public_key

  say "GitLab setup + package intake, and k3s + Flux in prod (in parallel)"
  start gitlab-setup gitlab_setup
  start prod remote prod prod platform/prod/bootstrap.sh "${LAB}/cosign.pub" platform/flux/bank-app.yaml \
    platform/flux/flux-lockdown.yaml
  finish

  close_window
  register_runners_and_import
  say "Platform ready ($((($(date +%s) - START) / 60)) min)."
  demo_or_instructions
}

# Shared by up and demo-reset.
register_runners_and_import() {
  say "Registering the runners and pre-pulling CI images"
  start build-runner remote build-runner -e ROLE=build -e STAGE=register \
    build-runner platform/runner/install.sh platform/harbor/mirror.txt
  start release-runner remote release-runner -e ROLE=release -e STAGE=register \
    release-runner platform/runner/install.sh platform/harbor/mirror.txt
  finish

  say "Importing the code into GitLab (bank/bank) as Security; developers work through merge requests"
  prepare_repository
  remote push gitlab platform/gitlab/push.sh "${LAB}/repo.bundle" || die "push (see ${LOGS}/push.log)"
  grep -E '^(pushed|bank/bank)' "${LOGS}/push.log" | sed 's/^/          /'
}

demo_or_instructions() {
  if [ "$DEMO" = manual ]; then
    cat <<EOF

  The first pipeline is running now and will stop at the CVE gate. Do the rest yourself in the web UIs:
  README.md, "Run the demo yourself". Logins: make passwords. Browser access: make vpn.
EOF
  else
    demo
  fi
}

# A fresh bank/bank project in a lab that exists: deletes the project (its history, merge requests and
# pipelines), recreates it, takes the Python packages in again and re-imports the code.
demo_reset() {
  load_settings
  [ -s "${LAB}/digests.txt" ] || die "no lab found from this laptop: run make up first"
  rm -f "${LOGS}"/*.log
  say "Deleting the GitLab project bank/bank"
  remote reset gitlab platform/gitlab/reset.sh platform/gitlab/reset.rb || die "see ${LOGS}/reset.log"
  say "Recreating it (settings, CI variables, runners) and taking the Python packages in again"
  open_window
  gitlab_setup || die "see ${LOGS}/gitlab-setup.log"
  close_window
  register_runners_and_import
  demo_or_instructions
}

demo() {
  [ -n "${PROJECT:-}" ] || load_settings
  say "Demo: CVE gate -> exception MR -> Security approval -> signed release (log: ${LOGS}/demo.log)"
  scripts/ssm-run.sh -e "PROJECT=${PROJECT}" gitlab platform/gitlab/demo.sh 2>&1 | tee "${LOGS}/demo.log" |
    { grep -E '^(==|pipeline|merge|release|RELEASE)' || true; } | sed 's/^/          /'
  grep -q '^RELEASE ' "${LOGS}/demo.log" || die "demo (see ${LOGS}/demo.log)"
  say "Waiting for Flux in prod to verify and install the release"
  release=$(awk '$1 == "RELEASE" { print $2 }' "${LOGS}/demo.log")
  digest=$(awk '$1 == "DIGEST" { print $2 }' "${LOGS}/demo.log")
  scripts/ssm-run.sh -e "EXPECTED_VERSION=${release}" -e "EXPECTED_DIGEST=${digest}" prod platform/prod/verify.sh \
    platform/prod/verify_release.py 2>&1 | tee "${LOGS}/verify.log" | sed 's/^/          /'
  grep -q '^HEALTHY' "${LOGS}/verify.log" || die "prod did not become healthy (see ${LOGS}/verify.log)"
  say "Done in $((($(date +%s) - START) / 60)) min."
  cat <<EOF

  Logins:      make passwords
  Web UIs:     make vpn, connect, then https://gitlab.lab.internal and https://harbor.lab.internal
  Prod state:  make status
  Delete all:  make down
EOF
}

passwords() {
  load_settings
  local p
  for p in gitlab/password-root gitlab/password-omeriko gitlab/password-security-lead harbor/admin-password; do
    printf '%-32s %s\n' "$p" "$(aws ssm get-parameter --name "/${PROJECT}/${p}" --with-decryption \
      --query Parameter.Value --output text 2>/dev/null || echo '(not created yet)')"
  done
  echo "Users: GitLab root / omeriko / security-lead, Harbor admin."
}

vpn() {
  load_settings
  (umask 077 && terraform -chdir=terraform output -raw client_vpn_config > bank-lab.ovpn)
  cat <<EOF
Wrote bank-lab.ovpn (it holds your VPN key: keep it private).
  Linux:          nmcli connection import type openvpn file bank-lab.ovpn
                  nmcli connection modify bank-lab ipv4.dns-search "~lab.internal" ipv4.never-default yes
                  nmcli connection up bank-lab
  macOS/Windows:  AWS VPN Client -> File -> Manage profiles -> Add profile -> bank-lab.ovpn
Then trust the lab CA in your browser:  terraform -chdir=terraform output -raw ca_cert_pem > lab-ca.crt
EOF
}

status() {
  load_settings
  aws ec2 describe-instances --filters "Name=tag:Project,Values=${PROJECT}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceType,PrivateIpAddress]' --output table
  scripts/ssm-run.sh prod platform/prod/verify.sh platform/prod/verify_release.py
}

down() {
  load_settings
  say "Deleting the lab (the Terraform state bucket stays; delete it by hand if you want)"
  terraform -chdir=terraform init -input=false -reconfigure -backend-config=backend.hcl > "${LOGS}/down.log" 2>&1
  export TF_VAR_alb_deletion_protection=false
  terraform -chdir=terraform apply -input=false -auto-approve -target=module.alb.aws_lb.this >> "${LOGS}/down.log" 2>&1 ||
    die "lifting the load balancer's deletion protection (see ${LOGS}/down.log)"
  terraform -chdir=terraform destroy -input=false -auto-approve >> "${LOGS}/down.log" 2>&1 ||
    die "terraform destroy (see ${LOGS}/down.log)"
  # Secrets the VMs wrote at runtime are not in Terraform's state.
  local names
  names=$(aws ssm get-parameters-by-path --path "/${PROJECT}" --recursive --query 'Parameters[].Name' --output text)
  # shellcheck disable=SC2086 # one name per word
  [ -z "$names" ] || printf '%s\n' $names | xargs -n 10 aws ssm delete-parameters --names > /dev/null
  rm -f bank-lab.ovpn "${LAB}/repo.bundle" "${LAB}/cosign.pub"
  say "Lab deleted."
}

case "${1:-}" in
  up | demo | passwords | vpn | status | down) "$1" ;;
  demo-reset) demo_reset ;;
  *)
    echo "usage: $0 up|demo|demo-reset|passwords|vpn|status|down" >&2
    exit 2
    ;;
esac
