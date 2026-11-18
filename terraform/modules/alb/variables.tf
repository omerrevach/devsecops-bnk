variable "name" {
  description = "Prefix for resource names (keep it short: AWS limits LB names to 32 characters)."
  type        = string
}

variable "domain" {
  description = "Internal DNS domain; each backend is served as <key>.<domain>."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "At least two subnets in different AZs (an AWS requirement for ALBs)."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "certificate_arn" {
  description = "ACM certificate covering every backend host name."
  type        = string
}

variable "backends" {
  description = "Backends keyed by short host name."
  type = map(object({
    instance_id          = string
    health_check_path    = string
    priority             = number       # listener rule order, must be unique
    allowed_source_cidrs = list(string) # networks allowed to use this host name
  }))
}

variable "deletion_protection" {
  description = "Protect the load balancer from accidental deletion."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  type    = number
  default = 90
}
