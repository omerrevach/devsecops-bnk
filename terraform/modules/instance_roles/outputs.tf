output "role_names" {
  value = { for vm, role in aws_iam_role.vm : vm => role.name }
}

output "role_arns" {
  value = { for vm, role in aws_iam_role.vm : vm => role.arn }
}

output "instance_profiles" {
  value = { for vm, profile in aws_iam_instance_profile.vm : vm => profile.name }
  # VMs start using their role as soon as they boot, so they are created only after its policies exist.
  depends_on = [aws_iam_role_policy.ssm_agent, aws_iam_role_policy.parameters, aws_iam_role_policy.parameter_writes]
}

output "secrets_key_arn" {
  description = "KMS key for SecureString parameters (alias/<name>-secrets)."
  value       = aws_kms_key.secrets.arn
}
