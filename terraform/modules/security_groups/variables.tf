variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "zone_cidrs" {
  description = "CIDR per zone (needs: public, build, dmz, prod, endpoints)."
  type        = map(string)
}

variable "dns_resolver_ip" {
  description = "IP of the VPC DNS resolver (VPC CIDR base + 2)."
  type        = string
}
