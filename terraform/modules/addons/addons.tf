# =============================================================================
# ADDONS MODULE — EKS Addons (separate lifecycle from cluster)
# =============================================================================
# WHY separate from EKS module?
#   - Addons update monthly, cluster updates quarterly
#   - If an addon fails, cluster still works
#   - Cleaner blast radius for changes
#
# ADDONS INSTALLED:
#   - coredns:              DNS resolution inside the cluster
#   - kube-proxy:           Network rules for Service routing
#   - vpc-cni:              AWS-native pod networking (1 IP per pod)
#   - pod-identity-agent:   Injects IAM credentials into pods
#   - aws-ebs-csi-driver:   Creates/attaches EBS volumes for pods
# =============================================================================

resource "aws_eks_addon" "coredns" {
  cluster_name                = var.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = var.cluster_name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = var.cluster_name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# --- Pod Identity Agent: MUST be installed before any Pod Identity associations ---
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = var.cluster_name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# --- EBS CSI Driver: needs Pod Identity for IAM permissions ---
resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = var.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_eks_pod_identity_association.ebs_csi
  ]

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
