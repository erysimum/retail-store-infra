# -----------------------------------------------------
# Pyrra Module — SLO-as-Code for Kubernetes
# -----------------------------------------------------
# Installs Pyrra: a controller that converts SLO YAMLs
# into Prometheus recording + alerting rules using
# Google's multi-window multi-burn-rate methodology.
#
# WHY PYRRA: Writing burn rate alerts by hand is hard.
#   - Pyrra generates 15+ rules per SLO automatically
#   - Implements Google SRE Workbook best practices
#   - Provides a UI for SLO status and error budget tracking
# -----------------------------------------------------

resource "helm_release" "pyrra" {
  name       = "pyrra"
  repository = "https://pyrra-dev.github.io/helm-charts"
  chart      = "pyrra"
  version    = var.chart_version
  namespace  = var.namespace

  values = [
    templatefile("${path.module}/values.yaml", {
      # Pyrra needs Prometheus to query for current SLO state
      prometheus_url = var.prometheus_url
    })
  ]

  timeout          = 900
  wait             = true
  disable_webhooks  = true
  create_namespace = false  # monitoring namespace already exists
}
