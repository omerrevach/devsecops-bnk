output "dns_name" {
  value = aws_lb.this.dns_name
}

output "zone_id" {
  description = "Hosted zone of the load balancer, for Route 53 alias records."
  value       = aws_lb.this.zone_id
}
