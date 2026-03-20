variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID (needed by AWS LB Controller to find subnets)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aws_lb_controller_chart_version" {
  description = "Helm chart version for AWS Load Balancer Controller"
  type        = string
  default     = "1.11.0"
}

variable "nginx_ingress_chart_version" {
  description = "Helm chart version for NGINX Ingress Controller"
  type        = string
  default     = "4.12.1"
}

variable "eks_dependency" {
  description = "Dependency to ensure EKS + addons are ready"
  type        = any
  default     = null
}
