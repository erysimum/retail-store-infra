#!/bin/bash
# =============================================================================
# DESTROY SCRIPT — Clean teardown of all infrastructure
# =============================================================================
# Run from: ~/projects/retail-store/retail-store-infra
#
# Why this script exists:
#   terraform destroy alone can fail because:
#   - NLB created by AWS LB Controller leaves orphaned security groups
#   - Network interfaces linger after NLB deletion
#   - Subnets can't delete while ENIs/SGs reference them
#   - Internet gateway can't detach while Elastic IPs are mapped
#   - EBS volumes created by CSI driver survive cluster deletion
#
# This script cleans up orphaned AWS resources BEFORE running terraform destroy.
# =============================================================================

set -e

REGION="ap-southeast-2"
ENV_DIR="terraform/environments/dev"

echo "============================================"
echo "  RETAIL STORE — INFRASTRUCTURE TEARDOWN"
echo "============================================"
echo ""

# --- Step 1: Get VPC ID from Terraform state ---
echo "[1/8] Getting VPC ID from Terraform state..."
VPC_ID=$(cd "$ENV_DIR" && terraform output -raw vpc_id 2>/dev/null || echo "")

if [ -z "$VPC_ID" ]; then
  echo "  No VPC found in Terraform state. Possibly already destroyed."
  echo "  Running terraform destroy anyway to clean up state..."
  cd "$ENV_DIR" && terraform destroy -auto-approve
  exit 0
fi

echo "  VPC ID: $VPC_ID"
echo ""

# --- Step 2: Delete orphaned load balancers ---
echo "[2/8] Checking for orphaned load balancers..."
LB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
  --output text 2>/dev/null || echo "")

if [ -n "$LB_ARNS" ] && [ "$LB_ARNS" != "None" ]; then
  for ARN in $LB_ARNS; do
    echo "  Deleting load balancer: $ARN"
    aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" --region "$REGION"
  done
  echo "  Waiting 60s for LB cleanup..."
  sleep 60
else
  echo "  No orphaned load balancers found."
fi
echo ""

# --- Step 3: Delete orphaned target groups ---
echo "[3/8] Checking for orphaned target groups..."
TG_ARNS=$(aws elbv2 describe-target-groups --region "$REGION" \
  --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" \
  --output text 2>/dev/null || echo "")

if [ -n "$TG_ARNS" ] && [ "$TG_ARNS" != "None" ]; then
  for ARN in $TG_ARNS; do
    echo "  Deleting target group: $ARN"
    aws elbv2 delete-target-group --target-group-arn "$ARN" --region "$REGION"
  done
else
  echo "  No orphaned target groups found."
fi
echo ""

# --- Step 4: Delete orphaned network interfaces ---
echo "[4/8] Checking for orphaned network interfaces..."
ENI_IDS=$(aws ec2 describe-network-interfaces --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "NetworkInterfaces[?Status=='available'].NetworkInterfaceId" \
  --output text 2>/dev/null || echo "")

if [ -n "$ENI_IDS" ] && [ "$ENI_IDS" != "None" ]; then
  for ENI in $ENI_IDS; do
    echo "  Deleting network interface: $ENI"
    aws ec2 delete-network-interface --network-interface-id "$ENI" --region "$REGION" 2>/dev/null || true
  done
else
  echo "  No orphaned network interfaces found."
fi
echo ""

# --- Step 5: Delete orphaned security groups (non-default) ---
echo "[5/8] Checking for orphaned security groups..."
SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[?GroupName!='default'].GroupId" \
  --output text 2>/dev/null || echo "")

if [ -n "$SG_IDS" ] && [ "$SG_IDS" != "None" ]; then
  for SG in $SG_IDS; do
    echo "  Deleting security group: $SG"
    aws ec2 delete-security-group --group-id "$SG" --region "$REGION" 2>/dev/null || true
  done
else
  echo "  No orphaned security groups found."
fi
echo ""

# --- Step 6: Delete orphaned EBS volumes created by Kubernetes CSI driver ---
# WHY: During terraform destroy, EKS kills the CSI controller pod BEFORE
# PVC deletion is processed. The CSI driver can't delete EBS volumes if it's
# already dead. Result: orphaned EBS volumes costing money.
# HOW: CSI driver tags every volume with kubernetes.io/created-for/pvc/namespace.
# We filter for "available" (detached) + that tag = only K8s-created volumes.
echo "[6/8] Checking for orphaned EBS volumes..."
EBS_IDS=$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=status,Values=available" \
            "Name=tag-key,Values=kubernetes.io/created-for/pvc/namespace" \
  --query "Volumes[].VolumeId" \
  --output text 2>/dev/null || echo "")

if [ -n "$EBS_IDS" ] && [ "$EBS_IDS" != "None" ]; then
  for VOL in $EBS_IDS; do
    echo "  Deleting EBS volume: $VOL"
    aws ec2 delete-volume --volume-id "$VOL" --region "$REGION"
  done
else
  echo "  No orphaned EBS volumes found."
fi
echo ""

# --- Step 7: Terraform destroy ---
echo "[7/8] Running terraform destroy..."
echo ""
cd "$ENV_DIR" && terraform destroy -auto-approve

echo ""
echo "============================================"
echo "  [8/8] VERIFYING CLEANUP"
echo "============================================"
echo ""

echo "EKS clusters:"
aws eks list-clusters --region "$REGION" --output table

echo ""
echo "Load balancers:"
aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'LoadBalancers[*].[LoadBalancerName,State.Code]' --output table 2>/dev/null || echo "  None"

echo ""
echo "VPCs (should only see default):"
aws ec2 describe-vpcs --region "$REGION" \
  --query 'Vpcs[*].[VpcId,Tags[?Key==`Name`].Value|[0],IsDefault]' --output table

echo ""
echo "NAT Gateways:"
aws ec2 describe-nat-gateways --region "$REGION" \
  --query 'NatGateways[?State!=`deleted`].[NatGatewayId,State]' --output table 2>/dev/null || echo "  None"

echo ""
echo "Elastic IPs:"
aws ec2 describe-addresses --region "$REGION" --output table 2>/dev/null || echo "  None"

echo ""
echo "EBS Volumes (should be empty or only non-k8s):"
aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=status,Values=available" \
  --query 'Volumes[*].[VolumeId,Size,State,Tags[?Key==`kubernetes.io/created-for/pvc/namespace`].Value|[0]]' \
  --output table 2>/dev/null || echo "  None"

echo ""
echo "============================================"
echo "  TEARDOWN COMPLETE — SLEEP PEACEFULLY"
echo "============================================"