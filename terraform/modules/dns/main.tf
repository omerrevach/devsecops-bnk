# Private DNS zone, visible only inside the VPC (and to Client VPN users, who use the VPC resolver).

resource "aws_route53_zone" "internal" {
  name = var.domain

  vpc {
    vpc_id = var.vpc_id
  }
}

# Hosts that are reached directly by IP (the egress proxy).
resource "aws_route53_record" "host" {
  #checkov:skip=CKV2_AWS_23:Points at the proxy instance's IP passed in from the compute module; Checkov does not follow module outputs.
  for_each = var.a_records

  zone_id = aws_route53_zone.internal.zone_id
  name    = "${each.key}.${var.domain}"
  type    = "A"
  ttl     = 60
  records = [each.value]
}

# Hosts served by the load balancer (GitLab, Harbor).
resource "aws_route53_record" "load_balanced" {
  for_each = toset(var.load_balancer_hosts)

  zone_id = aws_route53_zone.internal.zone_id
  name    = "${each.key}.${var.domain}"
  type    = "A"

  alias {
    name                   = var.load_balancer_dns_name
    zone_id                = var.load_balancer_zone_id
    evaluate_target_health = false
  }
}
