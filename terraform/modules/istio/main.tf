
# Create the istio-system namespace explicitly so we can manage labels.
# Kubernetes won't allow a Helm chart to label a namespace it didn't create.
resource "kubernetes_namespace_v1" "istio_system" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      # NOTE: Istio's own pods (istiod, gateways) get sidecar injection
      # disabled automatically — we don't need to label this namespace.
    }
  }
}

# Step 1: Install istio-base
# Installs CRDs (VirtualService, DestinationRule, Gateway, etc.)
# + cluster-wide RBAC
# + the istio-system namespace setup
resource "helm_release" "istio_base" {
  name       = "istio-base"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = var.chart_version
  namespace  = kubernetes_namespace_v1.istio_system.metadata[0].name

  # Helm tries to create the namespace by default; we already did.
  create_namespace = false

  # Heavy chart - give it time
  timeout          = 900
  wait             = true
  disable_webhooks = true

  depends_on = [
    kubernetes_namespace_v1.istio_system,
  ]
}

# Step 2: Install istiod (control plane)
# This is the brain that programs all the Envoy sidecars in the mesh.
# Depends on CRDs from istio-base.
resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.chart_version
  namespace  = kubernetes_namespace_v1.istio_system.metadata[0].name

  values = [
    yamlencode({
      # Replica count for HA. Dev = 1, prod = 2+.
      pilot = {
        autoscaleEnabled = false
        replicaCount     = var.istiod_replicas

        # Modest resources for dev. Bump in prod.
        resources = {
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
          limits = {
            memory = "512Mi"
          }
        }
      }

      # Enable Prometheus scraping of Envoy metrics
      # This is the key setting that makes istio_requests_total etc. available
      meshConfig = {
        enablePrometheusMerge = true

        # Access logging to stdout — easy to view via kubectl logs
        accessLogFile = "/dev/stdout"
      }

      # Sidecar default config
      global = {
        # Use Istio's built-in proxy resources (modest for dev)
        proxy = {
          resources = {
            requests = {
              cpu    = "10m"
              memory = "40Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
      }
    })
  ]

  create_namespace = false
  timeout          = 900
  wait             = true
  disable_webhooks = true

  depends_on = [
    helm_release.istio_base,
  ]
}