# =============================================================================
# DEV ENVIRONMENT — Root Module (v2)
# =============================================================================
# Calls 3 modules:
#   1. VPC    → network (unchanged)
#   2. EKS    → cluster + node groups (addons removed)
#   3. Addons → CoreDNS, kube-proxy, vpc-cni, ebs-csi, pod-identity
#
# Terraform resolves order from data flow:
#   VPC outputs vpc_id → EKS input
#   EKS outputs cluster_name → Addons input
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "retail-store-tfstate-2142"
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
# MODULE CALLS
# =============================================================================

# --- 1. Network ---
module "vpc" {
  source = "../../modules/vpc"

  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  private_subnet_cidrs = var.private_subnet_cidrs
  public_subnet_cidrs  = var.public_subnet_cidrs
}

# --- 2. Kubernetes Cluster ---
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

# --- 3. EKS Addons (separate lifecycle from cluster) ---
module "addons" {
  source = "../../modules/addons"

  cluster_name = module.eks.cluster_name
  project_name = var.project_name
  environment  = var.environment
}
