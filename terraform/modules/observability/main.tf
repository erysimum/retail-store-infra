# -----------------------------------------------------
# Observability Module — kube-prometheus-stack
# Installs: Prometheus, Grafana, Alertmanager,
#           node-exporter, kube-state-metrics,
#           prometheus-operator
# -----------------------------------------------------

# Fetch Grafana admin password from AWS Secrets Manager
# Same pattern used for GitHub PAT in argocd-image-updater module
data "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = var.grafana_admin_secret_name
}

locals {
  grafana_admin_password = jsondecode(
    data.aws_secretsmanager_secret_version.grafana_admin.secret_string
  )["password"]
}

# Create monitoring namespace explicitly
# (not via Helm createNamespace — we control labels and lifecycle)
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by"       = "terraform"
      "pod-security.kubernetes.io/enforce"  = "privileged"
      # node-exporter needs host network + privileged access
      # to read /proc and /sys for node-level metrics
    }
  }
}

# Install kube-prometheus-stack via Helm
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.chart_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  # Render values.yaml with variables interpolated
  values = [
    templatefile("${path.module}/values.yaml", {
      retention_days   = var.prometheus_retention_days
      storage_size     = var.prometheus_storage_size
      grafana_password = local.grafana_admin_password
    })
  ]

  # Chart is large — allow 10 minutes for all pods to come up
  timeout = 600

  # Block until all resources are ready
  wait = true

  # Don't create namespace — we already created it above
  create_namespace = false

  depends_on = [
    kubernetes_namespace_v1.monitoring,
  ]
}
