output "namespace" {
  description = "Namespace where the observability stack is installed"
  value       = kubernetes_namespace_v1.monitoring.metadata[0].name
}

output "grafana_service" {
  description = "Grafana service name for port-forwarding"
  value       = "kube-prometheus-stack-grafana"
}

output "grafana_port_forward_command" {
  description = "Copy-paste command to access Grafana locally"
  value       = "kubectl port-forward -n ${kubernetes_namespace_v1.monitoring.metadata[0].name} svc/kube-prometheus-stack-grafana 3000:80"
}

output "prometheus_service" {
  description = "Prometheus service name for port-forwarding and in-cluster queries"
  value       = "kube-prometheus-stack-prometheus"
}

output "prometheus_in_cluster_url" {
  description = "Prometheus URL for in-cluster references (Argo Rollouts AnalysisTemplate)"
  value       = "http://kube-prometheus-stack-prometheus.${kubernetes_namespace_v1.monitoring.metadata[0].name}.svc.cluster.local:9090"
}