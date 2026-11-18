output "instance_ids" {
  value = merge(
    { for vm, instance in aws_instance.vm : vm => instance.id },
    { proxy = aws_instance.proxy.id },
  )
}

output "private_ips" {
  value = merge(
    { for vm, instance in aws_instance.vm : vm => instance.private_ip },
    { proxy = aws_instance.proxy.private_ip },
  )
}
