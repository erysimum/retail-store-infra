# =============================================================================
# ARGOCD MODULE — Install ArgoCD via Helm (Terraform-managed)
# =============================================================================
# This replaces the manual "helm install" we did earlier.
# Now ArgoCD comes back automatically on every terraform apply.
#
# REQUIRES: EKS cluster must exist first (depends_on in root module)
# =============================================================================

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = var.argocd_chart_version

  # Wait for all pods to be ready before marking as complete
  wait    = true
  timeout = 600 # 10 minutes max

  # --- ArgoCD Configuration ---
  # server.service.type = NodePort (access via port-forward)
  set {
    name  = "server.service.type"
    value = "NodePort"
  }

  # Disable Dex (SSO) — we don't need it for dev
  set {
    name  = "dex.enabled"
    value = "false"
  }

  # Disable notifications — not needed yet
  set {
    name  = "notifications.enabled"
    value = "false"
  }

  depends_on = [var.eks_dependency]
}