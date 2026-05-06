output "namespace" {
  description = "Namespace where Pyrra is installed"
  value       = var.namespace
}

output "ui_port_forward_command" {
  description = "Command to access Pyrra UI for SLO status"
  value       = "kubectl port-forward -n ${var.namespace} svc/pyrra-api 9099:9099"
}
