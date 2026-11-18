# A small internal CA for the lab (a bank would use its own internal PKI instead).
# It issues:
#   - one certificate per backend host (GitLab, Harbor), delivered to the VM through SSM Parameter Store
#   - one certificate for the load balancer, imported into ACM
# All private keys live in the Terraform state, which is why the state bucket is locked down.

resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 8760 # 1 year
  allowed_uses          = ["cert_signing", "crl_signing", "digital_signature"]

  subject {
    common_name  = "${var.name} internal CA"
    organization = var.organization
  }
}

# ---------------------------------------------------------------------------
# Backend host certificates (load balancer -> VM traffic stays encrypted)
# ---------------------------------------------------------------------------

resource "tls_private_key" "host" {
  for_each = toset(var.hosts)

  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "host" {
  for_each = toset(var.hosts)

  private_key_pem = tls_private_key.host[each.key].private_key_pem
  dns_names       = ["${each.key}.${var.domain}"]

  subject {
    common_name = "${each.key}.${var.domain}"
  }
}

resource "tls_locally_signed_cert" "host" {
  for_each = toset(var.hosts)

  cert_request_pem      = tls_cert_request.host[each.key].cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 4380 # 6 months
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

# The VM fetches these at install time; they never appear in user-data.
resource "aws_ssm_parameter" "host_key" {
  for_each = toset(var.hosts)

  name   = "/${var.name}/pki/${each.key}/key"
  type   = "SecureString"
  key_id = var.secrets_key_arn
  value  = tls_private_key.host[each.key].private_key_pem
}

resource "aws_ssm_parameter" "host_cert" {
  for_each = toset(var.hosts)

  name   = "/${var.name}/pki/${each.key}/cert"
  type   = "SecureString"
  key_id = var.secrets_key_arn
  value  = "${tls_locally_signed_cert.host[each.key].cert_pem}${tls_self_signed_cert.ca.cert_pem}"
}

# ---------------------------------------------------------------------------
# Load balancer certificate: one certificate covering every public-facing name
# ---------------------------------------------------------------------------

resource "tls_private_key" "load_balancer" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "load_balancer" {
  private_key_pem = tls_private_key.load_balancer.private_key_pem
  dns_names       = [for host in var.hosts : "${host}.${var.domain}"]

  subject {
    common_name = "${var.hosts[0]}.${var.domain}"
  }
}

resource "tls_locally_signed_cert" "load_balancer" {
  cert_request_pem      = tls_cert_request.load_balancer.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 4380
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

resource "aws_acm_certificate" "load_balancer" {
  private_key       = tls_private_key.load_balancer.private_key_pem
  certificate_body  = tls_locally_signed_cert.load_balancer.cert_pem
  certificate_chain = tls_self_signed_cert.ca.cert_pem

  tags = { Name = "${var.name}-load-balancer" }

  # Lets a renewed certificate be attached before the old one is removed.
  lifecycle {
    create_before_destroy = true
  }
}
