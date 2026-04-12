variable "cluster_name" {
  type = string
}

variable "project_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "github_secret_name" {
  description = "Name of the Secrets Manager secret containing the GitHub PAT"
  type        = string
  default     = "retail-store/github-pat"
}

variable "github_username" {
  description = "GitHub username for git commits"
  type        = string
}

variable "gitops_repo_url" {
  description = "SSH or HTTPS URL of the gitops repo"
  type        = string
}