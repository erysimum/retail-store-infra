# =============================================================================
# VPC MODULE — Network foundation for EKS
# =============================================================================
# Uses the community terraform-aws-modules/vpc/aws module.
#
# WHY NOT write raw VPC resources?
#   - VPC has ~15 interconnected resources (subnets, route tables, IGW, NAT...)
#   - The community module is used by 50,000+ companies
#   - It handles edge cases we'd never think of
#   - Our value-add is the CONFIGURATION, not reimplementing networking
#
# COST DECISIONS:
#   - 2 AZs (not 3) — saves NAT Gateway costs, still HA for learning
#   - 1 NAT Gateway (not per-AZ) — saves $32/month per extra NAT
#   - Private subnets for EKS nodes (security best practice)
#   - Public subnets for ALB/NLB only
# =============================================================================

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-${var.environment}"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  # --- NAT Gateway ---
  # Required: pods in private subnets need internet to pull images
  # single_nat_gateway = true saves ~$64/month (vs one per AZ)
  enable_nat_gateway = true
  single_nat_gateway = true
  # In prod: single_nat_gateway = false (one per AZ for HA)

  # --- DNS (required for EKS and service discovery) ---
  enable_dns_hostnames = true
  enable_dns_support   = true

  # --- Tags required by EKS for subnet auto-discovery ---
  # Without these tags, EKS can't find where to place load balancers/nodes
  public_subnet_tags = {
    "kubernetes.io/role/elb"                                        = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}"   = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                               = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}"   = "shared"
    "karpenter.sh/discovery" = "${var.project_name}-${var.environment}"
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
