# =============================================================================
# BOOTSTRAP — Creates S3 + DynamoDB for Terraform Remote State
# =============================================================================
# This is the ONE Terraform config that uses local state.
# Run this ONCE, then never touch it again.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # NOTE: This intentionally uses LOCAL state.
  # The S3 bucket doesn't exist yet — that's what we're creating!
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "retail-store"
      ManagedBy   = "terraform"
      Environment = "shared"
      Component   = "bootstrap"
    }
  }
}

# --- S3 Bucket: Stores .tfstate files ---
resource "aws_s3_bucket" "terraform_state" {
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "Terraform State Store" }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- DynamoDB Table: State locking ---
resource "aws_dynamodb_table" "terraform_locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = { Name = "Terraform State Lock Table" }
}