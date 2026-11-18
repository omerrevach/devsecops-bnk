variable "domain" {
  description = "Private zone name, e.g. lab.internal."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "a_records" {
  description = "Short host name => private IP."
  type        = map(string)
  default     = {}
}

variable "load_balancer_hosts" {
  description = "Short host names that point at the load balancer."
  type        = list(string)
  default     = []
}

variable "load_balancer_dns_name" {
  type = string
}

variable "load_balancer_zone_id" {
  type = string
}
