# =============================================================================
# EKS MODULE — Cluster + Managed Node Groups (NO addons here)
# =============================================================================
# Addons moved to separate modules/addons/ for cleaner lifecycle.
# This module ONLY creates the cluster and node groups.
# =============================================================================

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.project_name}-${var.environment}"
  cluster_version = var.kubernetes_version

  # --- Network ---
  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # --- Cluster endpoint access ---
  cluster_endpoint_public_access = true # WSL2 kubectl access
  # prod: false + VPN/bastion

  # --- Managed Node Groups ---
  eks_managed_node_groups = {
    general = {
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      labels = {
        role        = "general"
        environment = var.environment
      }

      tags = {
        "karpenter.sh/discovery" = "${var.project_name}-${var.environment}"
      }
    }
  }

  # --- Access ---
  enable_cluster_creator_admin_permissions = true

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
