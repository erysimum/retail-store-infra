

# =============================================================================
# HELM: AWS Load Balancer Controller (installs FIRST)
# =============================================================================
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = var.aws_lb_controller_chart_version

  wait    = true
  timeout = 300

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  # VPC ID needed for the controller to find subnets
  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  # Region for AWS API calls
  set {
    name  = "region"
    value = var.aws_region
  }

  depends_on = [
    aws_eks_pod_identity_association.aws_lb_controller,
    var.eks_dependency
  ]
}

# =============================================================================
# HELM: NGINX External Ingress Controller (installs AFTER LB Controller)
# =============================================================================
# Creates:
#   - NGINX pod in ingress-nginx namespace
#   - Service of type LoadBalancer (triggers NLB creation)
#   - IngressClass "external-nginx"
#
# AWS LB Controller sees the Service → creates public NLB in IP mode
# =============================================================================
resource "helm_release" "nginx_external" {
  name       = "nginx-external"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = "ingress-nginx"
  version    = var.nginx_ingress_chart_version

  create_namespace = true
  wait             = true
  timeout          = 300

  # IngressClass name — Ingress objects reference this
  set {
    name  = "controller.ingressClass"
    value = "external-nginx"
  }

  set {
    name  = "controller.ingressClassResource.name"
    value = "external-nginx"
  }

  # Make this the default ingress class (only one controller for now)
  set {
    name  = "controller.ingressClassResource.default"
    value = "true"
  }

  # --- NLB Configuration via Service annotations ---
  # These annotations tell AWS LB Controller HOW to create the NLB

  # Use NLB (not ALB)
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "external"
  }

  # PUBLIC NLB — internet-facing, in public subnets
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  # IP mode — target group points directly to NGINX pod IPs
  # No NodePort hop, better performance
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type"
    value = "ip"
  }

  # NGINX must install AFTER AWS LB Controller is running
  # Otherwise legacy cloud provider creates Classic LB in NodePort mode
  depends_on = [helm_release.aws_lb_controller]
}
