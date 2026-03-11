output "namespace" {
  description = "Namespace where ArgoCD is installed"
  value       = "argocd"
}

output "port_forward_command" {
  description = "Command to access ArgoCD UI"
  value       = "kubectl port-forward svc/argocd-server -n argocd 8080:443"
}

output "get_password_command" {
  description = "Command to get the initial admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
}