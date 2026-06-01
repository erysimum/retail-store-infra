resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = var.argocd_chart_version

  # Wait for all pods to be ready before marking as complete
  timeout = 900
  wait    = true

  # Roll back on failed install instead of leaving release in 'failed' state
  atomic          = true
  cleanup_on_fail = true

  # --- ArgoCD Configuration ---

  # server.service.type = NodePort (access via port-forward)
  set {
    name  = "server.service.type"
    value = "NodePort"
  }


  set {
    name  = "dex.enabled"
    value = "false"
  }


  set {
    name  = "notifications.enabled"
    value = "false"
  }

  # Auto-create the argocd-redis Secret with a random password.
  # Without this, the Redis pod fails with CreateContainerConfigError
  # because the chart expects this Secret to exist (chart 7.x security hardening).
  set {
    name  = "redisSecretInit.enabled"
    value = "true"
  }

  depends_on = [var.eks_dependency]
}