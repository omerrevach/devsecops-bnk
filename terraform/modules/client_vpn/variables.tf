variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "domain" {
  description = "Internal DNS domain (the server certificate is vpn.<domain>)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Subnet the VPN endpoint is attached to."
  type        = string
}

variable "security_group_id" {
  description = "Security group applied to VPN traffic inside the VPC."
  type        = string
}

variable "client_cidr" {
  description = "Addresses handed out to VPN clients. Must not overlap the VPC; /22 or larger."
  type        = string
}

variable "dns_server" {
  description = "DNS server pushed to clients (the VPC resolver)."
  type        = string
}

variable "allowed_cidrs" {
  description = "Networks VPN users may reach."
  type        = list(string)
}

variable "client_name" {
  description = "Common name in the client certificate."
  type        = string
  default     = "lab-admin"
}

variable "client_cert_validity_hours" {
  type    = number
  default = 2160 # 90 days
}
