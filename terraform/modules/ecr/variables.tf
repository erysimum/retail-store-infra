variable "project_name" {
  description = "Project name (used as ECR repo prefix)"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "repository_names" {
  description = "List of repository names to create"
  type        = list(string)
}