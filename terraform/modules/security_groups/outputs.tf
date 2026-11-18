output "ids" {
  description = "Security group ID per role."
  value       = { for role, sg in aws_security_group.this : role => sg.id }
}
