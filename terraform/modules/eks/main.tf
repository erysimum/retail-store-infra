# =============================================================================
# EKS MODULE — Kubernetes cluster with Managed Node Groups
# =============================================================================
# Uses the community terraform-aws-modules/eks/aws module.
#
# EKS MODULE — Kubernetes cluster with Managed Node Groups
# Modern 2026 pattern: Pod Identity + Karpenter-ready bootstrap node group
# =============================================================================
# This module provisions:
# - EKS control plane
# - One bootstrap Managed Node Group (ON_DEMAND, minimal nodes)
# - Core EKS addons (CoreDNS, kube-proxy, VPC CNI, EBS CSI, Pod Identity Agent)
# - IAM role + Pod Identity association for EBS CSI driver
# - Tags and labels for Karpenter auto-discovery
# =============================================================================
# PHASE A (this file):
#   - EKS control plane ($0.10/hr)
#   - One Managed Node Group (2 x t3.medium)
#   
#   - Core EKS addons (CoreDNS, kube-proxy, vpc-cni, ebs-csi)
#
# PHASE B (later, via Helm):
#   - Karpenter installed as Helm chart
#   - Karpenter NodePool + EC2NodeClass
#   - MNG becomes bootstrap-only, Karpenter handles scaling
#
# COST:
#   - t3.medium = 2 vCPU, 4GB RAM, ~$0.052/hr in ap-southeast-2
#   - 2 nodes = enough for our 5 services + system pods
#   - min=1, desired=2, max=3 — safety cap
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
  cluster_endpoint_public_access  = false  # production best practice
  cluster_endpoint_private_access = true

  # --- Pod Identity approach (IRSA disabled) ---
  enable_irsa = false

  # --- Managed Addons ---
  cluster_addons = {
    coredns = {
      most_recent = true
    }

    kube-proxy = {
      most_recent = true
    }

    vpc-cni = {
      most_recent = true
    }

    aws-ebs-csi-driver = {
      most_recent = true
    }

    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  # --- Bootstrap Managed Node Group ---
  eks_managed_node_groups = {
    bootstrap = {
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      labels = {
        role = "bootstrap"
      }

      tags = {
        "karpenter.sh/discovery" = "${var.project_name}-${var.environment}"
      }
    }
  }

  # --- Access management ---
  enable_cluster_creator_admin_permissions = true

  # --- Resource tags ---
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# Pod Identity: IAM role + association for EBS CSI driver
# =============================================================================

# Trust policy for Pod Identity
data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# IAM role for EBS CSI driver
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.project_name}-${var.environment}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# Attach AWS managed policy for EBS CSI driver
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Pod Identity association: links service account to IAM role
resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}