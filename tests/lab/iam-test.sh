#!/usr/bin/env bash
# IAM controls, proven with AWS's policy simulator against the REAL deployed roles (no secret is read):
#   1. each VM role can read and decrypt only its own Parameter Store secrets, for every read action
#   2. only the release runner's role can sign with the KMS key
#   3. the lab admin user cannot escalate: no role without the boundary, no removing it, no passing other
#      roles; and a lab role with AdministratorAccess attached still gets nothing beyond the boundary
# Needs: a running lab (make up) and scripts/create-lab-user.sh applied.
set -euo pipefail
cd "$(dirname "$0")/../.."
PROJECT="${PROJECT:-bank-lab}"
account=$(aws sts get-caller-identity --query Account --output text)
region=$(aws configure get region || echo eu-central-1)
param="arn:aws:ssm:${region}:${account}:parameter/${PROJECT}"
key=$(aws kms describe-key --key-id "alias/${PROJECT}-secrets" --query KeyMetadata.Arn --output text)
sign_key=$(aws kms describe-key --key-id "alias/${PROJECT}-release-signing" --query KeyMetadata.Arn --output text)
failed=0

decision() { # decision <principal arn> <action> <resource> [context entries...]
  local principal="$1" action="$2" resource="$3"
  shift 3
  aws iam simulate-principal-policy --policy-source-arn "$principal" --action-names "$action" \
    --resource-arns "$resource" ${1:+--context-entries "$@"} --query 'EvaluationResults[0].EvalDecision' --output text
}
expect() { # expect <allowed|denied> <label> <decision>
  local got=denied
  [ "$3" = allowed ] && got=allowed
  if [ "$got" = "$1" ]; then echo "ok   $1: $2"; else echo "FAIL expected $1, got $3: $2"; failed=1; fi
}
kms_context() { echo "ContextKeyName=kms:EncryptionContext:PARAMETER_ARN,ContextKeyValues=$1,ContextKeyType=string"; }

echo "== 1. secrets: own allowed, everyone else's denied (GetParameter, GetParameters, GetParameterHistory, kms:Decrypt)"
# role : a parameter it must read : a parameter it must NOT read
for row in \
  "build-runner:gitlab/runner-token-build:gitlab/token-security-lead" \
  "build-runner:gitlab/runner-token-build:harbor/robot-ci-release" \
  "release-runner:gitlab/runner-token-release:gitlab/runner-token-build" \
  "prod:harbor/robot-prod-pull:pki/gitlab/key" \
  "prod:harbor/robot-prod-pull:gitlab/token-omeriko" \
  "harbor:pki/harbor/key:gitlab/password-root" \
  "gitlab:harbor/robot-ci-build:harbor/robot-prod-pull" \
  "proxy:-:harbor/admin-password"; do
  IFS=: read -r vm own other <<<"$row"
  role="arn:aws:iam::${account}:role/${PROJECT}-${vm}"
  for action in ssm:GetParameter ssm:GetParameters ssm:GetParameterHistory; do
    [ "$own" != "-" ] && expect allowed "$vm $action $own" "$(decision "$role" "$action" "$param/$own")"
    expect denied "$vm $action $other" "$(decision "$role" "$action" "$param/$other")"
  done
  [ "$own" != "-" ] && expect allowed "$vm kms:Decrypt for $own" "$(decision "$role" kms:Decrypt "$key" "$(kms_context "$param/$own")")"
  expect denied "$vm kms:Decrypt for $other" "$(decision "$role" kms:Decrypt "$key" "$(kms_context "$param/$other")")"
done

echo "== 2. signing: only the release runner"
for vm in release-runner build-runner gitlab harbor prod proxy; do
  want=denied
  [ "$vm" = release-runner ] && want=allowed
  expect "$want" "$vm kms:Sign" "$(decision "arn:aws:iam::${account}:role/${PROJECT}-${vm}" kms:Sign "$sign_key")"
done

echo "== 3. lab admin user cannot escalate"
user="arn:aws:iam::${account}:user/bank-lab-admin"
boundary="arn:aws:iam::${account}:policy/${PROJECT}-boundary"
bctx="ContextKeyName=iam:PermissionsBoundary,ContextKeyValues=${boundary},ContextKeyType=string"
lab_role="arn:aws:iam::${account}:role/${PROJECT}-test"
expect allowed "create a lab role WITH the boundary" "$(decision "$user" iam:CreateRole "$lab_role" "$bctx")"
expect denied "create a lab role WITHOUT the boundary" "$(decision "$user" iam:CreateRole "$lab_role")"
expect denied "create a role outside bank-lab-*" "$(decision "$user" iam:CreateRole "arn:aws:iam::${account}:role/admin" "$bctx")"
expect denied "remove a role's boundary" "$(decision "$user" iam:DeleteRolePermissionsBoundary "$lab_role")"
expect denied "edit the boundary policy" "$(decision "$user" iam:CreatePolicyVersion "$boundary")"
expect denied "pass a non-lab role (e.g. to SSM automation)" "$(decision "$user" iam:PassRole "arn:aws:iam::${account}:role/OrganizationAccountAccessRole")"
expect denied "give itself a policy" "$(decision "$user" iam:AttachUserPolicy "$user")"
# A lab role with AdministratorAccess attached: the boundary still caps it.
admin=$(aws iam get-policy-version --policy-arn arn:aws:iam::aws:policy/AdministratorAccess --version-id \
  "$(aws iam get-policy --policy-arn arn:aws:iam::aws:policy/AdministratorAccess --query Policy.DefaultVersionId --output text)" \
  --query PolicyVersion.Document --output json)
bdoc=$(aws iam get-policy-version --policy-arn "$boundary" --version-id \
  "$(aws iam get-policy --policy-arn "$boundary" --query Policy.DefaultVersionId --output text)" \
  --query PolicyVersion.Document --output json)
for action in iam:CreateUser iam:AttachRolePolicy s3:DeleteBucket ec2:TerminateInstances; do
  got=$(aws iam simulate-custom-policy --policy-input-list "$admin" --permissions-boundary-policy-input-list "$bdoc" \
    --action-names "$action" --query 'EvaluationResults[0].EvalDecision' --output text)
  expect denied "lab role + AdministratorAccess: $action" "$got"
done

[ "$failed" = 0 ] || { echo "FAIL: IAM controls"; exit 1; }
echo "PASS: IAM controls"
