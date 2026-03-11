variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64 encoded cluster CA certificate"
  type        = string
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "7.8.13"
}

variable "eks_dependency" {
  description = "Dependency marker to ensure EKS is ready before ArgoCD installs"
  type        = any
  default     = null
}