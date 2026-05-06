variable "namespace" {
  description = "Kubernetes namespace where Pyrra is installed"
  type        = string
  default     = "monitoring"
}

variable "chart_version" {
  description = "Pyrra Helm chart version - pin explicitly"
  type        = string
  default     = "0.7.4"
}

variable "prometheus_url" {
  description = "In-cluster URL for Prometheus (for Pyrra to query SLO state)"
  type        = string
}
