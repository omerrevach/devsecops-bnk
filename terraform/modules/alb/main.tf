# Internal Application Load Balancer: the single HTTPS entry point for GitLab and Harbor.
# It is not reachable from the internet. It routes by host name, and each host also has a
# source-network allowlist, so for example prod can reach Harbor but never GitLab.

data "aws_caller_identity" "current" {}

resource "aws_lb" "this" {
  name                       = "${var.name}-internal"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = var.subnet_ids
  security_groups            = [var.security_group_id]
  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
  idle_timeout               = 300 # large image layers take a while to upload

  access_logs {
    bucket  = aws_s3_bucket.access_logs.id
    enabled = true
  }

  # The load balancer checks it can write to the bucket when logging is turned on.
  depends_on = [aws_s3_bucket_policy.access_logs]
}

resource "aws_lb_target_group" "backend" {
  for_each = var.backends

  name        = "${var.name}-${each.key}"
  vpc_id      = var.vpc_id
  target_type = "instance"
  protocol    = "HTTPS" # traffic stays encrypted all the way to the VM
  port        = 443

  health_check {
    protocol = "HTTPS"
    path     = each.value.health_check_path
    matcher  = "200"
  }
}

resource "aws_lb_target_group_attachment" "backend" {
  for_each = var.backends

  target_group_arn = aws_lb_target_group.backend[each.key].arn
  target_id        = each.value.instance_id
  port             = 443
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-Res-2021-06" # TLS 1.2+ with strong ciphers only
  certificate_arn   = var.certificate_arn

  # Unknown host names (or a raw IP) get a 404 instead of reaching a backend.
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "backend" {
  for_each = var.backends

  listener_arn = aws_lb_listener.https.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend[each.key].arn
  }

  condition {
    host_header {
      values = ["${each.key}.${var.domain}"]
    }
  }

  condition {
    source_ip {
      values = each.value.allowed_source_cidrs
    }
  }
}

# ---------------------------------------------------------------------------
# Access logs bucket
# ---------------------------------------------------------------------------

# AWS-owned account that writes load balancer logs in this region.
data "aws_elb_service_account" "this" {}

resource "aws_s3_bucket" "access_logs" {
  #checkov:skip=CKV_AWS_145:Load balancer access logs only support S3-managed encryption (SSE-S3), not KMS.
  #checkov:skip=CKV_AWS_18:This bucket is itself a log destination; logging it would need another bucket.
  #checkov:skip=CKV_AWS_144:Single-region lab; cross-region replication of access logs is not needed.
  #checkov:skip=CKV2_AWS_62:Nothing consumes events about new log files.
  bucket        = "${var.name}-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # lab: allow "terraform destroy" even when logs exist
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Load balancer logs support only S3-managed encryption (not KMS).
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "LoadBalancerWritesLogs"
        Effect    = "Allow"
        Principal = { AWS = data.aws_elb_service_account.this.arn }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid       = "DenyPlainHttp"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.access_logs.arn, "${aws_s3_bucket.access_logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.access_logs]
}
