variable "cluster_name" {
  description = "EKS cluster name (used for tagging and references)"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the stack will be installed"
  type        = string
  default     = "monitoring"
}

variable "chart_version" {
  description = "kube-prometheus-stack Helm chart version. Pin explicitly — do not use latest."
  type        = string
  default     = "65.5.0"
}

variable "prometheus_retention_days" {
  description = "How many days of metrics to retain on disk"
  type        = number
  default     = 7
}

variable "prometheus_storage_size" {
  description = "PVC size for Prometheus TSDB"
  type        = string
  default     = "10Gi"
}

variable "grafana_admin_secret_name" {
  description = "AWS Secrets Manager secret name containing Grafana admin password"
  type        = string
  default     = "retail-store/grafana-admin"
}

variable "aws_region" {
  description = "AWS region (needed for Secrets Manager lookup)"
  type        = string
}