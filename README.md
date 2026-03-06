# retail-store-infra

Terraform infrastructure for the Retail Store EKS platform.

## Structure

```
terraform/
├── bootstrap/           ← Run ONCE: creates S3 + DynamoDB for state
├── modules/
│   ├── vpc/             ← VPC, subnets, NAT gateway
│   ├── eks/             ← EKS cluster, managed node groups, IRSA
│   └── rds/             ← RDS PostgreSQL (added in Week 3+)
└── environments/
    ├── dev/             ← terraform apply HERE
    └── prod/            ← Structure only (not applied)
```

## Quick Start

```bash
# 1. Bootstrap (one-time only)
cd terraform/bootstrap
terraform init && terraform apply

# 2. Deploy dev environment
cd ../environments/dev
terraform init && terraform apply   # ~15 min

# 3. Configure kubectl
aws eks update-kubeconfig --region ap-southeast-2 --name retail-store-dev
kubectl get nodes

# 4. When done practicing — DESTROY to stop billing
cd ../../..
./destroy.sh dev
```

## Cost Control

```bash
./cost-check.sh          # What's running?
./destroy.sh dev         # Tear it all down (~10 min)
```

## Estimated Cost (24/7)

| Resource         | $/month |
|-----------------|---------|
| EKS Control Plane | $73   |
| NAT Gateway      | $32    |
| 2x t3.medium     | $60    |
| **Total**        | **~$165** |

**Strategy:** terraform apply → practice → ./destroy.sh dev → sleep free.
