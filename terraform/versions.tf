terraform {
  # 1.11+ is needed for S3-native state locking (use_lockfile) - no DynamoDB table required.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Remote state in S3 (bucket created by ./bootstrap). Bucket and region come from backend.hcl:
  #   terraform init -backend-config=backend.hcl
  # The state holds private keys (lab CA, VPN), so the bucket is encrypted, versioned and private.
  backend "s3" {
    key          = "bank-lab/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
