# Bank lab: an air-gapped CI/CD environment on AWS.
# This file only wires the modules together; each module's main.tf explains what it builds.

data "aws_caller_identity" "current" {}

locals {
  # Created once by scripts/create-lab-user.sh; every lab role must carry it.
  permissions_boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project}-boundary"
  zone_cidrs               = { for zone, cfg in var.zones : zone => cfg.cidr }
  dns_resolver_ip          = cidrhost(var.vpc_cidr, 2) # AWS puts the VPC DNS resolver at base + 2
}

module "network" {
  source = "./modules/network"

  name                = var.project
  region              = var.region
  vpc_cidr            = var.vpc_cidr
  zones               = var.zones
  public_zone         = "public"
  endpoints_zone      = "endpoints"
  interface_endpoints = ["ssm", "ssmmessages", "ec2messages", "kms"]

  permissions_boundary_arn = local.permissions_boundary_arn

  # Domain isolation: these zone pairs can never talk, whatever the security groups say.
  nacl_deny = {
    build = ["prod", "vpn"]
    prod  = ["build", "vpn"]
  }
}

module "security_groups" {
  source = "./modules/security_groups"

  name            = var.project
  vpc_id          = module.network.vpc_id
  zone_cidrs      = local.zone_cidrs
  dns_resolver_ip = local.dns_resolver_ip
}

module "instance_roles" {
  source = "./modules/instance_roles"

  name  = var.project
  roles = ["proxy", "gitlab", "build-runner", "release-runner", "harbor", "prod"]

  permissions_boundary_arn = local.permissions_boundary_arn

  # Who may read/write which secret in Parameter Store (/bank-lab/...):
  #   pki/*     TLS keys (Terraform)          gitlab/*  passwords, tokens (GitLab VM)
  #   harbor/*  admin + robot passwords (Harbor VM)
  parameter_access = {
    gitlab         = { read = ["pki/gitlab/*", "gitlab/*", "harbor/robot-ci-*"], write = ["gitlab/*"] }
    harbor         = { read = ["pki/harbor/*"], write = ["harbor/*"] }
    build-runner   = { read = ["gitlab/runner-token-build"] }
    release-runner = { read = ["gitlab/runner-token-release"] }
    prod           = { read = ["harbor/robot-prod-pull"] }
  }
}

module "pki" {
  source = "./modules/pki"

  name         = var.project
  organization = "Bank Lab"
  domain       = var.domain
  hosts        = ["gitlab", "harbor"]

  secrets_key_arn = module.instance_roles.secrets_key_arn
}

module "signing_key" {
  source = "./modules/signing_key"

  name             = var.project
  signer_role_name = module.instance_roles.role_names["release-runner"]
  signer_role_arn  = module.instance_roles.role_arns["release-runner"]
}

module "compute" {
  source = "./modules/compute"

  name                = var.project
  region              = var.region
  domain              = var.domain
  instance_types      = var.instance_types
  subnet_ids          = module.network.subnet_ids
  zone_cidrs          = local.zone_cidrs
  security_group_ids  = module.security_groups.ids
  instance_profiles   = module.instance_roles.instance_profiles
  ca_cert_pem         = module.pki.ca_cert_pem
  harbor_feed_domains = var.harbor_feed_domains
  bootstrap_domains   = var.bootstrap_domains
}

module "alb" {
  source = "./modules/alb"

  name                = var.project
  domain              = var.domain
  vpc_id              = module.network.vpc_id
  subnet_ids          = [module.network.subnet_ids["dmz"], module.network.subnet_ids["dmz-b"]]
  security_group_id   = module.security_groups.ids["alb"]
  certificate_arn     = module.pki.load_balancer_certificate_arn
  deletion_protection = var.alb_deletion_protection

  # Prod is deliberately missing from GitLab's list: it may pull releases from Harbor, nothing more.
  backends = {
    harbor = {
      instance_id          = module.compute.instance_ids["harbor"]
      health_check_path    = "/api/v2.0/ping"
      priority             = 10
      allowed_source_cidrs = [local.zone_cidrs["build"], local.zone_cidrs["prod"], local.zone_cidrs["vpn"]]
    }
    gitlab = {
      instance_id          = module.compute.instance_ids["gitlab"]
      health_check_path    = "/users/sign_in"
      priority             = 20
      allowed_source_cidrs = [local.zone_cidrs["build"], local.zone_cidrs["vpn"]]
    }
  }
}

module "dns" {
  source = "./modules/dns"

  domain                 = var.domain
  vpc_id                 = module.network.vpc_id
  a_records              = { proxy = module.compute.private_ips["proxy"] }
  load_balancer_hosts    = ["gitlab", "harbor"]
  load_balancer_dns_name = module.alb.dns_name
  load_balancer_zone_id  = module.alb.zone_id
}

module "client_vpn" {
  source = "./modules/client_vpn"
  count  = var.enable_client_vpn ? 1 : 0

  name              = var.project
  domain            = var.domain
  vpc_id            = module.network.vpc_id
  subnet_id         = module.network.subnet_ids["vpn"]
  security_group_id = module.security_groups.ids["vpn"]
  client_cidr       = var.vpn_client_cidr
  dns_server        = local.dns_resolver_ip

  # VPN users reach the load balancer (both of its subnets) and DNS - nothing else.
  allowed_cidrs = [
    local.zone_cidrs["dmz"],
    local.zone_cidrs["dmz-b"],
    "${local.dns_resolver_ip}/32",
  ]
}
