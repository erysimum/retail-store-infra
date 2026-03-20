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

resource "aws_iam_role" "aws_lb_controller" {
  name               = "${var.project_name}-${var.environment}-aws-lb-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# --- IAM Policy for AWS LB Controller ---
# This policy allows the controller to create/manage NLBs, ALBs,
# target groups, security groups, and related AWS resources.
resource "aws_iam_policy" "aws_lb_controller" {
  name        = "${var.project_name}-${var.environment}-aws-lb-controller"
  description = "IAM policy for AWS Load Balancer Controller"

  policy = file("${path.module}/lb-controller-policy.json")
}

resource "aws_iam_role_policy_attachment" "aws_lb_controller" {
  role       = aws_iam_role.aws_lb_controller.name
  policy_arn = aws_iam_policy.aws_lb_controller.arn
}

# --- Pod Identity Association ---
# "aws-load-balancer-controller SA in kube-system gets this IAM role"
resource "aws_eks_pod_identity_association" "aws_lb_controller" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.aws_lb_controller.arn
}
