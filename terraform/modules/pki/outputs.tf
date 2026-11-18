output "ca_cert_pem" {
  description = "Public lab CA certificate (safe to share)."
  value       = tls_self_signed_cert.ca.cert_pem
}

output "load_balancer_certificate_arn" {
  value = aws_acm_certificate.load_balancer.arn
}
