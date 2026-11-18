output "instance_ids" {
  description = "VM instance IDs, for: aws ssm start-session --target <id>"
  value       = module.compute.instance_ids
}

output "private_ips" {
  value = module.compute.private_ips
}

output "cosign_key" {
  description = "Signing key reference for cosign (--key)."
  value       = module.signing_key.cosign_key_ref
}

output "ca_cert_pem" {
  description = "Public lab CA certificate. Save it: terraform output -raw ca_cert_pem > ../lab-ca.crt"
  value       = module.pki.ca_cert_pem
}

output "load_balancer_dns_name" {
  value = module.alb.dns_name
}

output "client_vpn_endpoint_id" {
  value = var.enable_client_vpn ? module.client_vpn[0].endpoint_id : null
}

output "client_vpn_config" {
  description = "OpenVPN profile (contains a private key): terraform output -raw client_vpn_config > ~/bank-lab.ovpn"
  sensitive   = true
  value       = var.enable_client_vpn ? module.client_vpn[0].client_config : null
}

# make up writes this to the proxy at the start of setup and empties it at the end.
output "harbor_feed_domains" {
  value = var.harbor_feed_domains
}

output "bootstrap_domains" {
  value = var.bootstrap_domains
}
