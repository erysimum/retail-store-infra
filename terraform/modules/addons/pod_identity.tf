# =============================================================================
# POD IDENTITY — IAM Roles for EKS Pods (newer replacement for IRSA)
# =============================================================================
# How it works:
#   1. IAM Role with trust policy for pods.eks.amazonaws.com
#   2. Attach permission policy (what the pod CAN do)
#   3. Associate: cluster + namespace + service_account → IAM role
#   4. Pod Identity Agent injects credentials automatically
#
# vs IRSA (old way):
#   IRSA:         Pod → SA → OIDC → STS → IAM Role (complex)
#   Pod Identity: Pod → SA → Agent → IAM Role (simpler, AWS recommended)
# =============================================================================

# --- Trust Policy ---
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# --- IAM Role for EBS CSI Driver ---
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.project_name}-${var.environment}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# --- Attach AWS-managed EBS CSI policy ---
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# --- Pod Identity Association ---
# "ebs-csi-controller-sa in kube-system namespace gets this IAM role"
resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}
