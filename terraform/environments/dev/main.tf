# =============================================================================
# DEV ENVIRONMENT — Root Module (v3: + ArgoCD via Helm)
# =============================================================================
# Calls 4 modules:
#   1. VPC    → network
#   2. EKS    → cluster + node groups
#   3. Addons → CoreDNS, kube-proxy, vpc-cni, ebs-csi, pod-identity
#   4. ArgoCD → GitOps engine via Helm
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
}
  }

  backend "s3" {
    bucket         = "retail-store-tfstate-2142"
    key            = "environments/dev/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "retail-store-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# --- Helm Provider ---
# Connects to EKS cluster to install Helm charts (ArgoCD)
# Uses the same auth as kubectl — AWS EKS token
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

# --- Kubernetes Provider ---
# Needed for resources that talk directly to Kubernetes API
# (e.g., patching StorageClass annotations)
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

# =============================================================================
# MODULE CALLS
# =============================================================================

# --- 1. Network ---
module "vpc" {
  source = "../../modules/vpc"

  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  private_subnet_cidrs = var.private_subnet_cidrs
  public_subnet_cidrs  = var.public_subnet_cidrs
  database_subnet_cidrs = var.database_subnet_cidrs
}

# --- 2. Kubernetes Cluster ---
module "eks" {
  source = "../../modules/eks"

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  kubernetes_version  = var.kubernetes_version
  node_instance_types = var.node_instance_types
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_desired_size   = var.node_desired_size
}

# --- 3. EKS Addons ---
module "addons" {
  source = "../../modules/addons"

  cluster_name = module.eks.cluster_name
  project_name = var.project_name
  environment  = var.environment
}

# --- 4. ArgoCD (GitOps Engine) ---
module "argocd" {
  source = "../../modules/argocd"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data

  # Ensure EKS + addons are fully ready before installing ArgoCD
  eks_dependency = module.addons
}

# --- 5. Ingress (AWS Load Balancer Controller + NGINX) ---
module "ingress" {
  source = "../../modules/ingress"

  cluster_name = module.eks.cluster_name
  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.vpc.vpc_id
  aws_region   = var.aws_region

  # Must wait for EKS + addons to be fully ready
  eks_dependency = module.addons
}

# --- 6. ECR (Container Image Registry) ---
module "ecr" {
  source = "../../modules/ecr"

  project_name     = var.project_name
  environment      = var.environment
  repository_names = ["catalog"]
}

# --- 7. GitHub OIDC (for CI/CD pipeline) ---
module "github_oidc" {
  source = "../../modules/github-oidc"

  project_name = var.project_name
  github_org   = "erysimum"
  github_repo  = "retail-store-app"
}