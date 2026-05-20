variable "chart_version" {
  description = "Istio chart version (must match base and istiod). Latest stable: 1.29.2"
  type        = string
  default     = "1.29.2"
}

variable "namespace" {
  description = "Namespace for Istio control plane components"
  type        = string
  default     = "istio-system"
}

variable "istiod_replicas" {
  description = "Number of istiod control plane replicas. 1 for dev; 2+ for prod (HA)."
  type        = number
  default     = 1
}