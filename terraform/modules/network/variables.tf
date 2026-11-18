variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "region" {
  description = "AWS region; zone AZ letters are appended to it."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
}

variable "zones" {
  description = "Security zones: one subnet per zone, with its CIDR and AZ letter (a, b, ...)."
  type = map(object({
    cidr = string
    az   = string
  }))
}

variable "public_zone" {
  description = "The only zone that gets a route to the internet gateway."
  type        = string
}

variable "endpoints_zone" {
  description = "Zone that holds the VPC interface endpoints."
  type        = string
}

variable "interface_endpoints" {
  description = "AWS services reachable privately through interface endpoints."
  type        = list(string)
}

variable "nacl_deny" {
  description = "For each zone, the zones it must never exchange traffic with (enforced by its NACL)."
  type        = map(list(string))
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the flow-logs role."
  type        = string
}
