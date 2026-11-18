output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "backend_hcl" {
  description = "Content for ../backend.hcl"
  value       = "bucket = \"${aws_s3_bucket.state.id}\"\nregion = \"${var.region}\"\n"
}
