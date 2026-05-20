output "namespace" {
  description = "The namespace where Istio control plane is installed"
  value       = kubernetes_namespace_v1.istio_system.metadata[0].name
}

output "chart_version" {
  description = "Istio chart version installed (for downstream module references)"
  value       = var.chart_version
}

output "istiod_service" {
  description = "DNS name of the istiod service (for sidecars to discover)"
  value       = "istiod.${var.namespace}.svc.cluster.local"
}