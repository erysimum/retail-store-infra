# =============================================================================
# DEV ENVIRONMENT — Root Module
# =============================================================================
# Run from here: terraform init → terraform plan → terraform apply
#
# This calls our VPC and EKS modules and wires their outputs together.
# The S3 backend stores state remotely (created by bootstrap).
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # --- Remote State Backend ---
  # Uses the S3 bucket + DynamoDB table created by bootstrap.
  # Each environment gets its own state file path (key).
  backend "s3" {
    bucket         = "retail-store-tfstate-2142" # Your bootstrap bucket name
    key            = "environments/dev/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "retail-store-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# =============================================================================
# MODULE CALLS — This is where modules get wired together
# =============================================================================

# --- Step 1: Create the network ---
module "vpc" {
  source = "../../modules/vpc"

  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  private_subnet_cidrs = var.private_subnet_cidrs
  public_subnet_cidrs  = var.public_subnet_cidrs
}

# --- Step 2: Create EKS inside the VPC ---
# module.vpc.vpc_id = output from VPC flows as input to EKS
module "eks" {
  source = "../../modules/eks"

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  kubernetes_version  = var.kubernetes_version
  node_instance_types = var.node_instance_types
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_desired_size   = var.node_desired_size
}
