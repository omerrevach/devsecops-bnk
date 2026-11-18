variable "name" {
  description = "Prefix for the key alias."
  type        = string
}

variable "signer_role_name" {
  description = "IAM role that may sign (gets an inline policy)."
  type        = string
}

variable "signer_role_arn" {
  description = "Same role, named in the key policy."
  type        = string
}
