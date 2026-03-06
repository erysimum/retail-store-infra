#!/bin/bash
# =============================================================================
# DESTROY SCRIPT — Tears down ALL AWS resources to stop billing
# =============================================================================
# Usage: ./destroy.sh dev
#
# Run this EVERY TIME you're done practicing.
# EKS + NAT = ~$5/day if left running.
#
# Does NOT destroy: S3 state bucket + DynamoDB lock table ($0 cost)
# =============================================================================

set -e

ENVIRONMENT=${1:-dev}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_DIR="${SCRIPT_DIR}/terraform/environments/${ENVIRONMENT}"

echo "============================================="
echo "  DESTROYING: ${ENVIRONMENT} environment"
echo "============================================="
echo ""
echo "This will destroy:"
echo "  - EKS cluster and all nodes"
echo "  - VPC, subnets, NAT gateway"
echo "  - Load balancers, security groups"
echo ""

if [ ! -d "${ENV_DIR}" ]; then
  echo "ERROR: ${ENV_DIR} does not exist."
  exit 1
fi

cd "${ENV_DIR}"
echo "Running terraform destroy in: $(pwd)"
echo ""

terraform destroy -auto-approve

echo ""
echo "============================================="
echo "  ✅ ${ENVIRONMENT} DESTROYED"
echo "  Monthly cost: ~$0.00"
echo "  To rebuild: cd ${ENV_DIR} && terraform apply"
echo "============================================="
