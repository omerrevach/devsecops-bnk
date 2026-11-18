# One security group per role. The two tables below are the complete list of allowed connections:
# anything not listed is denied. Reading them top to bottom gives the whole firewall matrix.

locals {
  groups = {
    alb    = "Internal load balancer in front of GitLab and Harbor"
    vpn    = "Client VPN: admins reach the load balancer only"
    proxy  = "Squid egress proxy - the only path to the internet"
    gitlab = "Self-hosted GitLab (build zone)"
    runner = "GitLab runners - nothing connects in"
    harbor = "Harbor registry (DMZ) - the bridge between zones"
    prod   = "k3s production node - nothing connects in"
  }

  # Inbound. "from" is another security group or a CIDR.
  ingress_rules = {
    alb_from_runner = { group = "alb", port = 443, from_group = "runner", description = "Runners use GitLab and Harbor" }
    alb_from_prod   = { group = "alb", port = 443, from_group = "prod", description = "Prod pulls releases from Harbor" }
    alb_from_vpn    = { group = "alb", port = 443, from_group = "vpn", description = "Admins use the web UIs" }

    gitlab_from_alb = { group = "gitlab", port = 443, from_group = "alb", description = "HTTPS from the load balancer only" }
    harbor_from_alb = { group = "harbor", port = 443, from_group = "alb", description = "HTTPS from the load balancer only" }

    proxy_from_build = { group = "proxy", port = 3128, from_cidr = var.zone_cidrs["build"], description = "Build zone through the proxy" }
    proxy_from_dmz   = { group = "proxy", port = 3128, from_cidr = var.zone_cidrs["dmz"], description = "Harbor feed replication" }
    proxy_from_prod  = { group = "proxy", port = 3128, from_cidr = var.zone_cidrs["prod"], description = "Prod installers during setup" }
  }

  # Outbound. "to" is another security group or a CIDR.
  egress_rules = {
    alb_to_gitlab = { group = "alb", port = 443, to_group = "gitlab", description = "Forward to GitLab" }
    alb_to_harbor = { group = "alb", port = 443, to_group = "harbor", description = "Forward to Harbor" }

    vpn_to_alb     = { group = "vpn", port = 443, to_group = "alb", description = "Web UIs through the load balancer" }
    vpn_to_dns_udp = { group = "vpn", port = 53, protocol = "udp", to_cidr = "${var.dns_resolver_ip}/32", description = "VPC DNS resolver" }
    vpn_to_dns_tcp = { group = "vpn", port = 53, to_cidr = "${var.dns_resolver_ip}/32", description = "VPC DNS resolver" }

    proxy_to_https = { group = "proxy", port = 443, to_cidr = "0.0.0.0/0", description = "Internet HTTPS (Squid enforces the allowlist)" }
    proxy_to_http  = { group = "proxy", port = 80, to_cidr = "0.0.0.0/0", description = "Ubuntu apt mirrors (Squid enforces the allowlist)" }

    gitlab_to_proxy     = { group = "gitlab", port = 3128, to_cidr = var.zone_cidrs["public"], description = "Installers during setup only" }
    gitlab_to_endpoints = { group = "gitlab", port = 443, to_cidr = var.zone_cidrs["endpoints"], description = "AWS APIs (SSM)" }

    runner_to_alb       = { group = "runner", port = 443, to_group = "alb", description = "GitLab jobs and Harbor images" }
    runner_to_proxy     = { group = "runner", port = 3128, to_cidr = var.zone_cidrs["public"], description = "Installers during setup only" }
    runner_to_endpoints = { group = "runner", port = 443, to_cidr = var.zone_cidrs["endpoints"], description = "AWS APIs (SSM, KMS)" }

    harbor_to_proxy     = { group = "harbor", port = 3128, to_cidr = var.zone_cidrs["public"], description = "Feed replication" }
    harbor_to_endpoints = { group = "harbor", port = 443, to_cidr = var.zone_cidrs["endpoints"], description = "AWS APIs (SSM)" }

    prod_to_alb       = { group = "prod", port = 443, to_group = "alb", description = "Flux and image pulls from Harbor" }
    prod_to_proxy     = { group = "prod", port = 3128, to_cidr = var.zone_cidrs["public"], description = "Installers during setup only" }
    prod_to_endpoints = { group = "prod", port = 443, to_cidr = var.zone_cidrs["endpoints"], description = "AWS APIs (SSM)" }
  }
}

resource "aws_security_group" "this" {
  #checkov:skip=CKV2_AWS_5:Attached in the compute, alb and client_vpn modules; Checkov's graph does not follow module outputs.
  for_each = local.groups

  name        = "${var.name}-${each.key}"
  description = each.value
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-${each.key}" }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = local.ingress_rules

  security_group_id            = aws_security_group.this[each.value.group].id
  description                  = each.value.description
  ip_protocol                  = lookup(each.value, "protocol", "tcp")
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = can(each.value.from_group) ? aws_security_group.this[each.value.from_group].id : null
  cidr_ipv4                    = lookup(each.value, "from_cidr", null)

  tags = { Name = each.key }
}

resource "aws_vpc_security_group_egress_rule" "this" {
  for_each = local.egress_rules

  security_group_id            = aws_security_group.this[each.value.group].id
  description                  = each.value.description
  ip_protocol                  = lookup(each.value, "protocol", "tcp")
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = can(each.value.to_group) ? aws_security_group.this[each.value.to_group].id : null
  cidr_ipv4                    = lookup(each.value, "to_cidr", null)

  tags = { Name = each.key }
}
