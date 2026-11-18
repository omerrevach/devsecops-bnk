#!/usr/bin/env bash
# make up must refuse to touch AWS when the Terraform code is insecure.
# A copy of the repo gets a forbidden rule (SSH open to the internet); `scripts/lab.sh up` runs with a fake
# `terraform` and `aws` that only record their calls. Expected: Checkov fails the preflight, and terraform
# plan/apply are never called.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar --exclude=.git --exclude=.lab --exclude='.terraform' -cf - . | tar -xf - -C "$work"
cat >> "$work/terraform/main.tf" <<'TF'

# Forbidden on purpose: SSH from anywhere.
resource "aws_security_group_rule" "preflight_test_ssh" {
  type              = "ingress"
  security_group_id = module.security_groups.ids["proxy"]
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "preflight test"
}
TF
mkdir -p "$work/fakebin"
cat > "$work/fakebin/terraform" <<'SH'
#!/bin/sh
echo "terraform $*" >> "$CALLS"
exit 0
SH
cat > "$work/fakebin/aws" <<'SH'
#!/bin/sh
echo "aws $*" >> "$CALLS"
echo 123456789012
SH
chmod +x "$work/fakebin/"*
printf 'AWS_PROFILE=x\nAWS_REGION=eu-central-1\nPROJECT=bank-lab\n' > "$work/lab.env"
export CALLS="$work/calls.log"
: > "$CALLS"
if (cd "$work" && PATH="$work/fakebin:$PATH" bash scripts/lab.sh up > "$work/out.log" 2>&1); then
  echo "FAIL: make up succeeded with an insecure rule"; exit 1
fi
grep -q 'Terraform security scan failed' "$work/out.log" || { echo "FAIL: did not stop at the scan"; cat "$work/out.log"; exit 1; }
if grep -qE '^terraform .*(plan|apply)' "$CALLS"; then
  echo "FAIL: terraform plan/apply was called"; exit 1
fi
grep -E 'CKV_AWS_(24|260)' "$work/.lab/logs/preflight.log" | head -2 | sed 's/^/  /'
echo "ok: preflight stopped make up; terraform calls were only: $(cut -d' ' -f2-3 "$CALLS" | sort -u | tr '\n' ';')"
echo "PASS: insecure Terraform never reaches AWS"
