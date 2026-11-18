output "cosign_key_ref" {
  description = "Key reference for cosign (--key)."
  value       = "awskms:///${aws_kms_alias.signing.name}"
}
