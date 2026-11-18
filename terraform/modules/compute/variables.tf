variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "region" {
  type = string
}

variable "domain" {
  description = "Internal DNS domain (the proxy is proxy.<domain>)."
  type        = string
}

variable "instance_types" {
  description = "Instance type per VM: proxy, gitlab, build-runner, release-runner, harbor, prod."
  type        = map(string)
}

variable "subnet_ids" {
  description = "Subnet ID per zone."
  type        = map(string)
}

variable "zone_cidrs" {
  description = "CIDR per zone, used in the Squid allowlist."
  type        = map(string)
}

variable "security_group_ids" {
  description = "Security group ID per role."
  type        = map(string)
}

variable "instance_profiles" {
  description = "Instance profile name per VM."
  type        = map(string)
}

variable "ca_cert_pem" {
  description = "Lab CA certificate every VM must trust."
  type        = string
}

variable "harbor_feed_domains" {
  description = "Domains Harbor may always reach through the proxy."
  type        = list(string)
}

variable "bootstrap_domains" {
  description = "Domains any VM may reach through the proxy during first setup only."
  type        = list(string)
}
