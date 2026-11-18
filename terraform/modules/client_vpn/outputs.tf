output "endpoint_id" {
  value = aws_ec2_client_vpn_endpoint.this.id
}

output "client_config" {
  description = "OpenVPN profile with the client key embedded. Treat it like a password."
  sensitive   = true
  value = templatefile("${path.module}/client.ovpn.tftpl", {
    endpoint    = trimprefix(aws_ec2_client_vpn_endpoint.this.dns_name, "*.")
    ca_cert     = trimspace(tls_self_signed_cert.ca.cert_pem)
    client_cert = trimspace(tls_locally_signed_cert.client.cert_pem)
    client_key  = trimspace(tls_private_key.client.private_key_pem)
  })
}
