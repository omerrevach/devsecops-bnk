# One IAM role per VM. Each role gets the SSM agent (our replacement for SSH) and exactly the secrets it
# needs; anything beyond that is granted by the module that owns the resource (e.g. kms:Sign).
# Every role carries the lab's permissions boundary, so attached policies can never exceed it.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  parameter_arn = "arn:aws:ssm:${data.aws_region.current.region}:${local.account_id}:parameter/${var.name}"
}

resource "aws_iam_role" "vm" {
  for_each = toset(var.roles)

  name                 = "${var.name}-${each.key}"
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# The SSM agent's own actions. Deliberately NOT the AWS-managed AmazonSSMManagedInstanceCore: that
# policy also allows ssm:GetParameter(s) on every parameter, which would let any VM read every secret.
resource "aws_iam_role_policy" "ssm_agent" {
  #checkov:skip=CKV_AWS_355:SSM agent messaging actions do not support resource-level permissions (same as AWS's managed policy); no data reads are included
  #checkov:skip=CKV_AWS_290:Same: agent registration and messaging only; parameters and keys are granted separately, per path
  for_each = aws_iam_role.vm

  name = "ssm-agent"
  role = each.value.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:UpdateInstanceInformation", "ssm:ListAssociations", "ssm:ListInstanceAssociations",
        "ssm:DescribeAssociation", "ssm:GetDocument", "ssm:DescribeDocument", "ssm:UpdateAssociationStatus",
        "ssm:UpdateInstanceAssociationStatus", "ssm:PutInventory", "ssm:PutComplianceItems",
        "ssm:PutConfigurePackageResult", "ssm:GetManifest", "ssm:GetDeployablePatchSnapshotForInstance",
        "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
        "ec2messages:AcknowledgeMessage", "ec2messages:DeleteMessage", "ec2messages:FailMessage",
        "ec2messages:GetEndpoint", "ec2messages:GetMessages", "ec2messages:SendReply",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "vm" {
  for_each = aws_iam_role.vm

  name = each.value.name
  role = each.value.name
}

# Secrets in Parameter Store are encrypted with this key, not the shared aws/ssm key. SSM passes the
# parameter's ARN as KMS encryption context, so each role can decrypt only its own parameter paths.
resource "aws_kms_key" "secrets" {
  description         = "${var.name}: Parameter Store secrets"
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdministersTheKey"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # Whoever runs Terraform writes the TLS parameters and reads the human logins (make passwords).
        Sid       = "LabAdministratorUsesTheKey"
        Effect    = "Allow"
        Principal = { AWS = data.aws_caller_identity.current.arn }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:EnableKeyRotation", "kms:GetKeyRotationStatus"]
        Resource  = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# Every action that returns a parameter's value is listed: allowing only GetParameter would leave
# GetParameters / GetParameterHistory / GetParametersByPath to whatever else is attached.
resource "aws_iam_role_policy" "parameters" {
  for_each = var.parameter_access

  name = "parameter-store"
  role = aws_iam_role.vm[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"]
        Resource = [for path in each.value.read : "${local.parameter_arn}/${path}"]
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.secrets.arn
        Condition = { StringLike = {
          "kms:EncryptionContext:PARAMETER_ARN" = [for path in each.value.read : "${local.parameter_arn}/${path}"]
        } }
      },
    ]
  })
}

# Only the VMs that create secrets (GitLab, Harbor) may write, each under its own folder.
resource "aws_iam_role_policy" "parameter_writes" {
  for_each = { for role, access in var.parameter_access : role => access if length(access.write) > 0 }

  name = "parameter-store-write"
  role = aws_iam_role.vm[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:PutParameter"
        Resource = [for path in each.value.write : "${local.parameter_arn}/${path}"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.secrets.arn
        Condition = { StringLike = {
          "kms:EncryptionContext:PARAMETER_ARN" = [for path in each.value.write : "${local.parameter_arn}/${path}"]
        } }
      },
    ]
  })
}
