variable "cluster_name" {
  description = "EKS cluster name (used for tagging and references)"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the observability stack will be installed"
  type        = string
  default     = "monitoring"
}

variable "chart_version" {
  description = "kube-prometheus-stack Helm chart version — pin explicitly, never use latest"
  type        = string
  default     = "65.5.0"
}

variable "prometheus_retention_days" {
  description = "How many days of metrics to retain on disk"
  type        = number
  default     = 7
}

variable "prometheus_storage_size" {
  description = "PVC size for Prometheus TSDB storage"
  type        = string
  default     = "10Gi"
}

variable "grafana_admin_secret_name" {
  description = "AWS Secrets Manager secret name containing Grafana admin password"
  type        = string
  default     = "retail-store/grafana-admin"
}

variable "slack_webhook_secret_name" {
  description = "AWS Secrets Manager secret name containing Slack webhook URL"
  type        = string
  default     = "retail-store/slack-webhook"
}

variable "pagerduty_key_secret_name" {
  description = "AWS Secrets Manager secret name containing PagerDuty integration key"
  type        = string
  default     = "retail-store/pagerduty-key"
}

variable "aws_region" {
  description = "AWS region for Secrets Manager lookup"
  type        = string
}
