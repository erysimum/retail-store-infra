# =============================================================================
# ARGOCD IMAGE UPDATER MODULE
# =============================================================================
# Installs ArgoCD Image Updater via Helm.
#
# WHAT IT DOES:
#   - Watches ECR for new image tags
#   - When it finds a new tag matching our pattern (sha-*)
#   - Commits the updated image tag to the gitops repo
#   - ArgoCD picks up the change and syncs to cluster
#
# AUTHENTICATION:
#   - ECR: Pod Identity (IAM role → service account)
#   - GitHub: Personal Access Token from AWS Secrets Manager → K8s Secret
#
# WRITE-BACK METHOD: git
#   Image Updater commits directly to the gitops repo.
#   This keeps Git as the single source of truth (real GitOps).
# =============================================================================

# --- Fetch GitHub PAT from Secrets Manager ---
data "aws_secretsmanager_secret_version" "github_pat" {
  secret_id = var.github_secret_name
}

locals {
  github_token = jsondecode(data.aws_secretsmanager_secret_version.github_pat.secret_string)["token"]
}

# --- Kubernetes Secret for GitHub credentials ---
# Image Updater reads this to push commits to the gitops repo
resource "kubernetes_secret" "git_credentials" {
  metadata {
    name      = "argocd-image-updater-git-secret"
    namespace = "argocd"
    labels = {
      "app.kubernetes.io/part-of" = "argocd-image-updater"
    }
  }

  data = {
    username = var.github_username
    password = local.github_token
  }

  type = "Opaque"
}

# --- IAM Role for Image Updater (ECR read access) ---
resource "aws_iam_role" "image_updater" {
  name = "${var.project_name}-image-updater"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

# --- Attach ECR read-only policy ---
resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.image_updater.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# --- Pod Identity Association ---
resource "aws_eks_pod_identity_association" "image_updater" {
  cluster_name    = var.cluster_name
  namespace       = "argocd"
  service_account = "argocd-image-updater"
  role_arn        = aws_iam_role.image_updater.arn
}

# --- Helm Release: ArgoCD Image Updater ---
resource "helm_release" "image_updater" {
  name       = "argocd-image-updater"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-image-updater"
  namespace  = "argocd"

  depends_on = [
    kubernetes_secret.git_credentials,
    aws_eks_pod_identity_association.image_updater
  ]

  values = [
    yamlencode({
      config = {
        registries = [
          {
            name    = "ecr"
            prefix  = "${var.aws_region}.amazonaws.com"
            api_url = "https://${var.aws_region}.amazonaws.com"
            default = true
          }
        ]
      }
      serviceAccount = {
        create = true
        name   = "argocd-image-updater"
      }
      extraArgs = ["--log-level=debug"]
    })
  ]
}