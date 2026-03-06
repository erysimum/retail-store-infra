variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "availability_zones" {
  description = "List of AZs"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs"
  type        = list(string)
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
}

variable "node_instance_types" {
  description = "EC2 instance types for nodes"
  type        = list(string)
}

variable "node_min_size" {
  description = "Min nodes"
  type        = number
}

variable "node_max_size" {
  description = "Max nodes"
  type        = number
}

variable "node_desired_size" {
  description = "Desired nodes"
  type        = number
}
