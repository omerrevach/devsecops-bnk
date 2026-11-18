# Release-signing key used by cosign. It is asymmetric, so the private half never leaves KMS,
# and every signature is recorded in CloudTrail. Only one role (the release runner) may sign.

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "signing" {
  description              = "${var.name} release signing (cosign)"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Standard statement that lets IAM in this account manage the key.
        Sid       = "AccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "SignerMaySignOnly"
        Effect    = "Allow"
        Principal = { AWS = var.signer_role_arn }
        Action    = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
        Resource  = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "signing" {
  name          = "alias/${var.name}-release-signing"
  target_key_id = aws_kms_key.signing.key_id
}

# The matching IAM permission on the signer's side, limited to this one key.
resource "aws_iam_role_policy" "signer" {
  name = "sign-releases"
  role = var.signer_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
      Resource = aws_kms_key.signing.arn
    }]
  })
}
