#!/bin/bash
# =============================================================================
# COST CHECK — What billable resources are currently running?
# =============================================================================
# Usage: ./cost-check.sh
# =============================================================================

REGION="ap-southeast-2"

echo "============================================="
echo "  AWS COST CHECK — ap-southeast-2"
echo "============================================="
echo ""

echo "--- EKS Clusters (~\$0.10/hr each) ---"
aws eks list-clusters --region ${REGION} --query 'clusters' --output table 2>/dev/null || echo "  None"
echo ""

echo "--- Running EC2 Instances ---"
aws ec2 describe-instances --region ${REGION} \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime]' \
  --output table 2>/dev/null || echo "  None"
echo ""

echo "--- NAT Gateways (~\$0.045/hr each) ---"
aws ec2 describe-nat-gateways --region ${REGION} \
  --filter "Name=state,Values=available" \
  --query 'NatGateways[].[NatGatewayId,State,CreateTime]' \
  --output table 2>/dev/null || echo "  None"
echo ""

echo "--- Load Balancers (~\$0.025/hr each) ---"
aws elbv2 describe-load-balancers --region ${REGION} \
  --query 'LoadBalancers[].[LoadBalancerName,Type,State.Code]' \
  --output table 2>/dev/null || echo "  None"
echo ""

echo "--- RDS Instances ---"
aws rds describe-db-instances --region ${REGION} \
  --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceClass,DBInstanceStatus]' \
  --output table 2>/dev/null || echo "  None"
echo ""

echo "============================================="
echo "  If anything is running → ./destroy.sh dev"
echo "============================================="
