variable "aws_region" {
  description = "AWS region for the state bucket and lock table"
  type        = string
  default     = "ap-southeast-2"
}

variable "state_bucket_name" {
  description = "Name of the S3 bucket for Terraform state (must be globally unique)"
  type        = string
}

variable "lock_table_name" {
  description = "Name of the DynamoDB table for state locking"
  type        = string
  default     = "retail-store-terraform-locks"
}