# -----------------------------------------------------
# Observability Module — kube-prometheus-stack
# Installs: Prometheus, Grafana, Alertmanager,
#           node-exporter, kube-state-metrics,
#           prometheus-operator
# -----------------------------------------------------

# Fetch Grafana admin password from AWS Secrets Manager
data "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = var.grafana_admin_secret_name
}

# Fetch Slack webhook URL for Alertmanager
data "aws_secretsmanager_secret_version" "slack_webhook" {
  secret_id = var.slack_webhook_secret_name
}

# Fetch PagerDuty integration key for Alertmanager
data "aws_secretsmanager_secret_version" "pagerduty_key" {
  secret_id = var.pagerduty_key_secret_name
}

locals {
  grafana_admin_password = jsondecode(
    data.aws_secretsmanager_secret_version.grafana_admin.secret_string
  )["password"]

  slack_webhook_url = jsondecode(
    data.aws_secretsmanager_secret_version.slack_webhook.secret_string
  )["url"]

  pagerduty_integration_key = jsondecode(
    data.aws_secretsmanager_secret_version.pagerduty_key.secret_string
  )["key"]
}

# Create monitoring namespace explicitly
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by"        = "terraform"
      "pod-security.kubernetes.io/enforce"  = "privileged"
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

  values = [
    templatefile("${path.module}/values.yaml", {
      retention_days            = var.prometheus_retention_days
      storage_size              = var.prometheus_storage_size
      grafana_password          = local.grafana_admin_password
      slack_webhook_url         = local.slack_webhook_url
      pagerduty_integration_key = local.pagerduty_integration_key
    })
  ]

  timeout          = 600
  wait             = true
  create_namespace = false

  depends_on = [
    kubernetes_namespace_v1.monitoring,
  ]
}
