# =============================================================================
# DEV ENVIRONMENT VALUES
# =============================================================================
# Same modules, same code as prod — different values.
# dev:  t3.medium, 2 nodes, 2 AZs, single NAT
# prod: m5.large, 3+ nodes, 3 AZs, NAT per AZ
# =============================================================================

aws_region   = "ap-southeast-2"
project_name = "retail-store"
environment  = "dev"

# --- Network ---
vpc_cidr             = "10.0.0.0/16"
availability_zones   = ["ap-southeast-2a", "ap-southeast-2b"]
private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
public_subnet_cidrs  = ["10.0.101.0/24", "10.0.102.0/24"]
database_subnet_cidrs = ["10.0.201.0/24", "10.0.202.0/24"]

# --- EKS ---
kubernetes_version  = "1.31"
node_instance_types = ["t3.medium"]
node_min_size       = 1
node_max_size       = 3
node_desired_size   = 2
