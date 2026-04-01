output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API endpoint"
  value       = module.eks.cluster_endpoint
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "configure_kubectl" {
  description = "Run this command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "argocd_port_forward" {
  description = "Access ArgoCD UI"
  value       = module.argocd.port_forward_command
}

output "argocd_password" {
  description = "Get ArgoCD admin password"
  value       = module.argocd.get_password_command
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}