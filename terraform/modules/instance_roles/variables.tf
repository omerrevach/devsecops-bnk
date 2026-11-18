variable "name" {
  description = "Prefix for role names and parameter paths."
  type        = string
}

variable "roles" {
  description = "One IAM role and instance profile is created per entry."
  type        = list(string)
}

variable "parameter_access" {
  description = "Role => Parameter Store paths under /<name>/ it may read and write (wildcards allowed)."
  type = map(object({
    read  = list(string)
    write = optional(list(string), [])
  }))
  default = {}
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary every role must carry (created by scripts/create-lab-user.sh)."
  type        = string
}
