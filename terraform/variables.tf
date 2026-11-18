variable "region" {
  description = "AWS region for the lab."
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "bank-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,14}$", var.project))
    error_message = "Use 3-15 lowercase letters, digits or dashes (AWS caps load balancer names at 32 characters)."
  }
}

variable "domain" {
  description = "Private DNS zone used inside the VPC."
  type        = string
  default     = "lab.internal"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "zones" {
  description = "One subnet per security zone: its CIDR and AZ letter."
  type = map(object({
    cidr = string
    az   = string
  }))
  default = {
    public    = { cidr = "10.20.0.0/24", az = "a" }  # egress proxy only
    build     = { cidr = "10.20.10.0/24", az = "a" } # GitLab + runners
    dmz       = { cidr = "10.20.20.0/24", az = "a" } # Harbor + load balancer
    dmz-b     = { cidr = "10.20.21.0/24", az = "b" } # load balancer only (AWS needs a second AZ)
    prod      = { cidr = "10.20.30.0/24", az = "a" } # k3s
    endpoints = { cidr = "10.20.40.0/24", az = "a" } # VPC interface endpoints
    vpn       = { cidr = "10.20.50.0/24", az = "a" } # Client VPN network interface
  }

  validation {
    condition     = alltrue([for zone in ["public", "build", "dmz", "dmz-b", "prod", "endpoints", "vpn"] : contains(keys(var.zones), zone)])
    error_message = "zones must define public, build, dmz, dmz-b, prod, endpoints and vpn."
  }
}

variable "instance_types" {
  type = map(string)
  default = {
    proxy          = "t3.micro"
    gitlab         = "t3.xlarge" # 4 vCPU: GitLab installs and starts much faster
    build-runner   = "t3.medium" # Checkov, Trivy and image builds need 4 GB
    release-runner = "t3.micro"
    harbor         = "t3.medium"
    prod           = "t3.medium"
  }
}

variable "enable_client_vpn" {
  description = "Client VPN bills per hour even when the VMs are stopped; set false to remove it."
  type        = bool
  default     = true
}

variable "vpn_client_cidr" {
  description = "Addresses given to VPN clients (must not overlap the VPC)."
  type        = string
  default     = "10.99.0.0/22"
}

variable "alb_deletion_protection" {
  description = "Set to false (and apply) right before terraform destroy."
  type        = bool
  default     = true
}

variable "harbor_feed_domains" {
  description = "Domains Harbor may always reach through the proxy, to mirror feeds and images."
  type        = list(string)
  default = [
    "ghcr.io",
    "pkg-containers.githubusercontent.com",
    ".docker.io",
    ".docker.com",
    ".quay.io",
    ".gcr.io",
    ".pkg.dev",
    "storage.googleapis.com",
    "cgr.dev",                                                   # Chainguard images (the database image)
    "9236a389bd48b984df91adc1bc924620.r2.cloudflarestorage.com", # Chainguard's own layer storage, exact host only
  ]
}

variable "bootstrap_domains" {
  description = "Domains any VM may reach during first setup only (installers). make up closes it when setup is done."
  type        = list(string)
  # A leading dot also matches every subdomain. Squid refuses to start if a list holds both
  # ".example.com" and "x.example.com", so never add a subdomain of an entry already here.
  default = [
    ".ubuntu.com",
    ".gitlab.com",            # includes packages.gitlab.com
    "storage.googleapis.com", # packages.gitlab.com redirects the .deb downloads here
    "download.docker.com",
    "github.com",
    ".githubusercontent.com",
    "get.k3s.io",
    "pypi.org", # Python package intake (make up), then closed
    "files.pythonhosted.org",
    "awscli.amazonaws.com",
  ]
}
