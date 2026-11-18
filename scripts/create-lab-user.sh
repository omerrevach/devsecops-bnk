#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in --query strings are JMESPath, not shell
# Create the one IAM user used for this lab, and save its access key as the AWS CLI profile "bank-lab".
# Run once, from the repo root, with admin (or root) credentials. Safe to re-run.
#
#   User   bank-lab-admin   (CLI only, no console password)
#   Group  bank-lab-admins  (permissions live on the group, not the user)
#
# Used for: terraform (bootstrap + lab), SSM sessions / ssm-run.sh, Parameter Store, Client VPN config.
# Not used by: CI or the VMs. They use their own EC2 instance roles that Terraform creates.
#
# Permissions: AWS managed "full access" policies for the services the lab uses, plus an inline policy
# that lets the user create IAM roles only when they carry the bank-lab-boundary permissions boundary
# (which grants no IAM at all), never remove it, and pass roles only to EC2 and VPC Flow Logs. That closes
# the "create a role with admin rights and use it from an instance" escalation path.
#
# Run it with administrator rights (e.g. AWS CloudShell). Re-running updates the policies; it never
# creates a second access key.
set -euo pipefail

project=bank-lab
user=bank-lab-admin
group=bank-lab-admins
profile=bank-lab
region=eu-central-1
account_id=$(aws sts get-caller-identity --query Account --output text)

managed_policies=(
  AmazonEC2FullAccess               # VPC, subnets, VMs, Client VPN, and the load balancer (elasticloadbalancing:*)
  AmazonS3FullAccess                # Terraform state bucket, ALB access-log bucket
  AmazonRoute53FullAccess           # private zone lab.internal
  AWSCertificateManagerFullAccess   # load balancer and VPN certificates
  AmazonSSMFullAccess               # Session Manager, ssm-run.sh, Parameter Store
  CloudWatchLogsFullAccess          # flow logs, VPN connection logs
  AWSKeyManagementServicePowerUser  # create/manage the cosign signing key (cannot sign with it)
)

# Permissions boundary: the most any lab role can ever do, whatever policies get attached to it.
# VM roles need the SSM agent, their own parameters, the lab's KMS keys and (flow logs) CloudWatch Logs.
# It grants no IAM at all, so a lab role can never create or change identities.
boundary_name="${project}-boundary"
boundary_arn="arn:aws:iam::${account_id}:policy/${boundary_name}"
boundary_policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SsmAgent",
      "Effect": "Allow",
      "Action": ["ssm:UpdateInstanceInformation", "ssm:ListAssociations", "ssm:ListInstanceAssociations",
                 "ssm:DescribeAssociation", "ssm:GetDocument", "ssm:DescribeDocument",
                 "ssm:UpdateAssociationStatus", "ssm:UpdateInstanceAssociationStatus", "ssm:PutInventory",
                 "ssm:PutComplianceItems", "ssm:PutConfigurePackageResult", "ssm:GetManifest",
                 "ssm:GetDeployablePatchSnapshotForInstance",
                 "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
                 "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
                 "ec2messages:AcknowledgeMessage", "ec2messages:DeleteMessage", "ec2messages:FailMessage",
                 "ec2messages:GetEndpoint", "ec2messages:GetMessages", "ec2messages:SendReply"],
      "Resource": "*"
    },
    {
      "Sid": "LabParameters",
      "Effect": "Allow",
      "Action": ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory",
                 "ssm:GetParametersByPath", "ssm:PutParameter"],
      "Resource": "arn:aws:ssm:*:${account_id}:parameter/${project}/*"
    },
    {
      "Sid": "LabKeys",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:Sign", "kms:GetPublicKey",
                 "kms:DescribeKey"],
      "Resource": "arn:aws:kms:*:${account_id}:key/*"
    },
    {
      "Sid": "FlowLogs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups",
                 "logs:DescribeLogStreams"],
      "Resource": "*"
    }
  ]
}
EOF
)

# The lab user's own IAM rights. Roles must be named bank-lab-* AND carry the boundary; the boundary can
# never be removed; roles can be passed only to EC2 and VPC Flow Logs. AmazonSSMFullAccess would also allow
# passing any role to SSM, so that is denied explicitly for every role outside the lab.
iam_policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CreateOrChangeLabRolesOnlyWithBoundary",
      "Effect": "Allow",
      "Action": ["iam:CreateRole", "iam:PutRolePermissionsBoundary", "iam:AttachRolePolicy",
                 "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy"],
      "Resource": "arn:aws:iam::${account_id}:role/${project}-*",
      "Condition": {"StringEquals": {"iam:PermissionsBoundary": "${boundary_arn}"}}
    },
    {
      "Sid": "ManageLabRoles",
      "Effect": "Allow",
      "Action": ["iam:DeleteRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateRole",
                 "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy"],
      "Resource": "arn:aws:iam::${account_id}:role/${project}-*"
    },
    {
      "Sid": "ManageLabInstanceProfiles",
      "Effect": "Allow",
      "Action": ["iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:AddRoleToInstanceProfile",
                 "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile", "iam:UntagInstanceProfile"],
      "Resource": "arn:aws:iam::${account_id}:instance-profile/${project}-*"
    },
    {
      "Sid": "PassLabRolesToEc2AndFlowLogsOnly",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${account_id}:role/${project}-*",
      "Condition": {"StringEquals": {"iam:PassedToService": ["ec2.amazonaws.com", "vpc-flow-logs.amazonaws.com"]}}
    },
    {
      "Sid": "NeverPassOtherRoles",
      "Effect": "Deny",
      "Action": "iam:PassRole",
      "NotResource": "arn:aws:iam::${account_id}:role/${project}-*"
    },
    {
      "Sid": "NeverRemoveOrEditTheBoundary",
      "Effect": "Deny",
      "Action": ["iam:DeleteRolePermissionsBoundary", "iam:CreatePolicyVersion", "iam:DeletePolicy",
                 "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion"],
      "Resource": ["arn:aws:iam::${account_id}:role/*", "${boundary_arn}"]
    },
    {
      "Sid": "ServiceLinkedRoles",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "*"
    },
    {
      "Sid": "ReadIamAndSimulatePolicies",
      "Effect": "Allow",
      "Action": ["iam:Get*", "iam:List*", "iam:SimulatePrincipalPolicy", "iam:SimulateCustomPolicy"],
      "Resource": "*"
    },
    {
      "Sid": "KmsKeyLifecycle",
      "Effect": "Allow",
      "Action": ["kms:PutKeyPolicy", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion"],
      "Resource": "arn:aws:kms:*:${account_id}:key/*"
    },
    {
      "Sid": "RotateOwnAccessKey",
      "Effect": "Allow",
      "Action": ["iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:UpdateAccessKey"],
      "Resource": "arn:aws:iam::${account_id}:user/\${aws:username}"
    }
  ]
}
EOF
)

# Create the boundary, or update it (IAM keeps at most 5 versions: drop the oldest non-default one).
if aws iam get-policy --policy-arn "$boundary_arn" >/dev/null 2>&1; then
  old=$(aws iam list-policy-versions --policy-arn "$boundary_arn" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)
  for version in $old; do aws iam delete-policy-version --policy-arn "$boundary_arn" --version-id "$version"; done
  aws iam create-policy-version --policy-arn "$boundary_arn" --policy-document "$boundary_policy" \
    --set-as-default >/dev/null
else
  aws iam create-policy --policy-name "$boundary_name" --policy-document "$boundary_policy" \
    --description "Most any ${project} role may ever do" >/dev/null
fi

aws iam get-group --group-name "$group" >/dev/null 2>&1 || aws iam create-group --group-name "$group" >/dev/null
for policy in "${managed_policies[@]}"; do
  aws iam attach-group-policy --group-name "$group" --policy-arn "arn:aws:iam::aws:policy/$policy"
done
aws iam put-group-policy --group-name "$group" --policy-name bank-lab-iam --policy-document "$iam_policy"

aws iam get-user --user-name "$user" >/dev/null 2>&1 || aws iam create-user --user-name "$user" >/dev/null
aws iam add-user-to-group --user-name "$user" --group-name "$group"

# Create a key only if the user has none and the profile does not exist yet (re-running the script, e.g. in
# CloudShell to update the policies, never creates a second key). The secret goes straight into
# ~/.aws/credentials and is never printed.
if aws configure get aws_access_key_id --profile "$profile" >/dev/null 2>&1 ||
  [ "$(aws iam list-access-keys --user-name "$user" --query 'length(AccessKeyMetadata)')" != 0 ]; then
  echo "User $user already has an access key; no new key created. Policies and boundary updated."
else
  key=$(aws iam create-access-key --user-name "$user" --output json)
  aws configure set aws_access_key_id "$(jq -r .AccessKey.AccessKeyId <<<"$key")" --profile "$profile"
  aws configure set aws_secret_access_key "$(jq -r .AccessKey.SecretAccessKey <<<"$key")" --profile "$profile"
  aws configure set region "$region" --profile "$profile"
  unset key
  echo "Saved access key for $user as profile $profile."
fi
