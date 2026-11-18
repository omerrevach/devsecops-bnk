variable "name" {
  description = "Prefix for names and Parameter Store paths."
  type        = string
}

variable "organization" {
  description = "Organization name written into the CA certificate."
  type        = string
}

variable "domain" {
  description = "Internal DNS domain the certificates are issued for."
  type        = string
}

variable "hosts" {
  description = "Short host names (e.g. gitlab) that get a certificate under the domain."
  type        = list(string)
}

variable "secrets_key_arn" {
  description = "KMS key that encrypts the TLS keys in Parameter Store."
  type        = string
}
