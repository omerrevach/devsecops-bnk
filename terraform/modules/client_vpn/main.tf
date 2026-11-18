# AWS Client VPN for admins: your laptop joins the VPC network and uses its private DNS,
# so https://gitlab.<domain> works with no /etc/hosts entries and no port forwarding.
#
# - Login is by client certificate (mutual TLS), issued by a CA dedicated to the VPN.
# - Split tunnel: only traffic for the VPC goes through the VPN.
# - Authorization rules decide what VPN users may reach: the load balancer and DNS, nothing else.
# - Every connection is logged to CloudWatch.

# Client VPN only accepts RSA certificates, so the VPN has its own small RSA CA.
resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 8760
  allowed_uses          = ["cert_signing", "crl_signing", "digital_signature"]

  subject {
    common_name = "${var.name} VPN CA"
  }
}

# --- Server certificate (presented by the VPN endpoint) ---

resource "tls_private_key" "server" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "server" {
  private_key_pem = tls_private_key.server.private_key_pem
  dns_names       = ["vpn.${var.domain}"]

  subject {
    common_name = "vpn.${var.domain}"
  }
}

resource "tls_locally_signed_cert" "server" {
  cert_request_pem      = tls_cert_request.server.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 8760
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

resource "aws_acm_certificate" "server" {
  private_key       = tls_private_key.server.private_key_pem
  certificate_body  = tls_locally_signed_cert.server.cert_pem
  certificate_chain = tls_self_signed_cert.ca.cert_pem

  tags = { Name = "${var.name}-vpn-server" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Client certificate (goes into your .ovpn profile) ---

resource "tls_private_key" "client" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "client" {
  private_key_pem = tls_private_key.client.private_key_pem

  subject {
    common_name = var.client_name
  }
}

resource "tls_locally_signed_cert" "client" {
  cert_request_pem      = tls_cert_request.client.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = var.client_cert_validity_hours
  allowed_uses          = ["digital_signature", "key_encipherment", "client_auth"]
}

# --- The VPN endpoint ---

resource "aws_cloudwatch_log_group" "connections" {
  name              = "/${var.name}/client-vpn"
  retention_in_days = 365
}

resource "aws_cloudwatch_log_stream" "connections" {
  name           = "connections"
  log_group_name = aws_cloudwatch_log_group.connections.name
}

resource "aws_ec2_client_vpn_endpoint" "this" {
  description            = "${var.name} admin access"
  server_certificate_arn = aws_acm_certificate.server.arn
  client_cidr_block      = var.client_cidr
  vpc_id                 = var.vpc_id
  security_group_ids     = [var.security_group_id]
  dns_servers            = [var.dns_server]
  split_tunnel           = true
  transport_protocol     = "udp"
  session_timeout_hours  = 8
  self_service_portal    = "disabled"

  # Clients must present a certificate signed by the VPN CA. The server certificate's
  # chain is that same CA, so its ARN is used as the trust anchor (an AWS-documented shortcut).
  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = aws_acm_certificate.server.arn
  }

  connection_log_options {
    enabled               = true
    cloudwatch_log_group  = aws_cloudwatch_log_group.connections.name
    cloudwatch_log_stream = aws_cloudwatch_log_stream.connections.name
  }

  tags = { Name = "${var.name}-client-vpn" }
}

# Places the VPN's network interface in the VPN subnet. VPN traffic leaves from this subnet,
# which is what the load balancer's source-IP rules and the prod NACL match on.
resource "aws_ec2_client_vpn_network_association" "this" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  subnet_id              = var.subnet_id
}

# What connected users may reach. Everything else in the VPC is refused by the VPN itself.
resource "aws_ec2_client_vpn_authorization_rule" "allowed" {
  for_each = toset(var.allowed_cidrs)

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  target_network_cidr    = each.value
  authorize_all_groups   = true # certificate login has no user groups
  description            = "Admin access to ${each.value}"
}
