variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "project" {
  description = "Same prefix as the main stack."
  type        = string
  default     = "bank-lab"
}
