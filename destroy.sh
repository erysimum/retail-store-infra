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
#   - Helm releases (NGINX) timeout during destroy
#   - Security groups created AFTER cleanup but BEFORE VPC deletion
#   - Prometheus CRDs survive Helm uninstall and block namespace deletion
#   - PVCs stuck in Terminating if pods still mount them
#
# Improvements over v2:
#   - Deletes pods BEFORE PVCs (prevents Terminating stuck state)
#   - Explicitly cleans monitoring namespace (StatefulSets, Deployments)
#   - Cleans Prometheus Operator CRDs (survive Helm uninstall)
#   - Cleans orphaned EBS volumes tagged by CSI driver
# =============================================================================

set -e

REGION="ap-southeast-2"
ENV_DIR="terraform/environments/dev"

echo "============================================"
echo "  RETAIL STORE — INFRASTRUCTURE TEARDOWN"
echo "============================================"
echo ""

# --- Step 1: Get VPC ID from Terraform state ---
echo "[1/11] Getting VPC ID from Terraform state..."
VPC_ID=$(cd "$ENV_DIR" && terraform output -raw vpc_id 2>/dev/null || echo "")

if [ -z "$VPC_ID" ]; then
  echo "  No VPC found in Terraform state. Possibly already destroyed."
  echo "  Running terraform destroy anyway to clean up state..."
  cd "$ENV_DIR" && terraform destroy -auto-approve
  exit 0
fi

echo "  VPC ID: $VPC_ID"
echo ""

# --- Step 2: Pre-clean Kubernetes resources ---
echo "[2/11] Pre-cleaning Kubernetes resources..."
if kubectl cluster-info &>/dev/null; then
  echo "  Cluster is reachable. Cleaning up K8s resources..."

  # Delete ArgoCD Applications first (removes all app deployments cleanly)
  echo "  Deleting ArgoCD Applications..."
  kubectl delete application --all -n argocd --timeout=60s 2>/dev/null || true

  # Delete LoadBalancer services (triggers NLB deletion via LB Controller)
  echo "  Deleting LoadBalancer services..."
  kubectl delete svc -n ingress-nginx --all --timeout=60s 2>/dev/null || true

  # Wait for NLB to be fully deleted by AWS
  echo "  Waiting 90s for NLB cleanup..."
  sleep 90

  # -------------------------------------------------------
  # Clean monitoring namespace — ORDER MATTERS
  # 1. Delete Prometheus/Alertmanager custom resources
  #    (this tells the operator to tear down StatefulSets)
  # 2. Delete all pods (releases PVC mounts)
  # 3. Delete PVCs (triggers EBS volume deletion)
  # -------------------------------------------------------
  echo "  Cleaning monitoring namespace..."

  # Delete Prometheus and Alertmanager custom resources
  # The operator manages StatefulSets via these CRs — deleting the CR
  # tells the operator to cleanly tear down the StatefulSet and pods
  echo "    Deleting Prometheus custom resources..."
  kubectl delete prometheus --all -n monitoring --timeout=60s 2>/dev/null || true
  kubectl delete alertmanager --all -n monitoring --timeout=60s 2>/dev/null || true

  # Delete all deployments in monitoring (Grafana, operator, kube-state-metrics)
  echo "    Deleting monitoring deployments..."
  kubectl delete deployment --all -n monitoring --timeout=60s 2>/dev/null || true

  # Delete all daemonsets in monitoring (node-exporter)
  echo "    Deleting monitoring daemonsets..."
  kubectl delete daemonset --all -n monitoring --timeout=60s 2>/dev/null || true

  # Wait for pods to fully terminate before touching PVCs
  echo "    Waiting 30s for pods to terminate..."
  sleep 30

  # Now delete PVCs — pods are gone, so PVCs won't get stuck in Terminating
  echo "  Deleting all PVCs across all namespaces..."
  kubectl delete pvc --all -A --timeout=60s 2>/dev/null || true

  # Wait for EBS volumes to detach and delete
  echo "  Waiting 30s for EBS volume cleanup..."
  sleep 30
else
  echo "  Cluster not reachable. Skipping K8s pre-cleanup."
  echo "  (Will clean orphaned AWS resources in later steps)"
fi
echo ""

# --- Step 3: Delete orphaned load balancers ---
echo "[3/11] Checking for orphaned load balancers..."
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

# --- Step 4: Delete orphaned target groups ---
echo "[4/11] Checking for orphaned target groups..."
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

# --- Step 5: Delete orphaned network interfaces ---
echo "[5/11] Checking for orphaned network interfaces..."
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

# --- Step 6: Delete orphaned security groups ---
echo "[6/11] Checking for orphaned security groups..."
SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[?GroupName!='default'].GroupId" \
  --output text 2>/dev/null || echo "")

if [ -n "$SG_IDS" ] && [ "$SG_IDS" != "None" ]; then
  # First: revoke all ingress/egress rules that reference other SGs
  for SG in $SG_IDS; do
    echo "  Revoking rules for: $SG"
    INGRESS=$(aws ec2 describe-security-groups --group-ids "$SG" --region "$REGION" \
      --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
    if [ "$INGRESS" != "[]" ] && [ -n "$INGRESS" ]; then
      aws ec2 revoke-security-group-ingress --group-id "$SG" --region "$REGION" \
        --ip-permissions "$INGRESS" 2>/dev/null || true
    fi
    EGRESS=$(aws ec2 describe-security-groups --group-ids "$SG" --region "$REGION" \
      --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)
    if [ "$EGRESS" != "[]" ] && [ -n "$EGRESS" ]; then
      aws ec2 revoke-security-group-egress --group-id "$SG" --region "$REGION" \
        --ip-permissions "$EGRESS" 2>/dev/null || true
    fi
  done
  # Second: delete the SGs
  for SG in $SG_IDS; do
    echo "  Deleting security group: $SG"
    aws ec2 delete-security-group --group-id "$SG" --region "$REGION" 2>/dev/null || true
  done
else
  echo "  No orphaned security groups found."
fi
echo ""

# --- Step 7: Delete orphaned EBS volumes ---
echo "[7/11] Checking for orphaned EBS volumes..."
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

# --- Step 8: Terraform destroy ---
echo "[8/11] Running terraform destroy..."
echo ""
set +e
cd "$ENV_DIR" && terraform destroy -auto-approve
TF_EXIT=$?
set -e

# --- Step 9: If terraform failed, retry cleanup and destroy ---
if [ $TF_EXIT -ne 0 ]; then
  echo ""
  echo "============================================"
  echo "  [9/11] TERRAFORM FAILED — RETRYING"
  echo "============================================"
  echo ""
  echo "  Cleaning up resources that appeared during destroy..."

  # Re-check security groups (the #1 blocker for VPC deletion)
  SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text 2>/dev/null || echo "")

  if [ -n "$SG_IDS" ] && [ "$SG_IDS" != "None" ]; then
    for SG in $SG_IDS; do
      echo "  Revoking rules and deleting: $SG"
      INGRESS=$(aws ec2 describe-security-groups --group-ids "$SG" --region "$REGION" \
        --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
      if [ "$INGRESS" != "[]" ] && [ -n "$INGRESS" ]; then
        aws ec2 revoke-security-group-ingress --group-id "$SG" --region "$REGION" \
          --ip-permissions "$INGRESS" 2>/dev/null || true
      fi
      aws ec2 delete-security-group --group-id "$SG" --region "$REGION" 2>/dev/null || true
    done
  fi

  # Re-check ENIs
  ENI_IDS=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "NetworkInterfaces[?Status=='available'].NetworkInterfaceId" \
    --output text 2>/dev/null || echo "")

  if [ -n "$ENI_IDS" ] && [ "$ENI_IDS" != "None" ]; then
    for ENI in $ENI_IDS; do
      echo "  Deleting network interface: $ENI"
      aws ec2 delete-network-interface --network-interface-id "$ENI" --region "$REGION" 2>/dev/null || true
    done
  fi

  # Re-check EBS volumes
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
  fi

  echo ""
  echo "  Retrying terraform destroy..."
  cd "$ENV_DIR" && terraform destroy -auto-approve
fi

# --- Step 10: Clean up Prometheus CRDs ---
# WHY: Prometheus Operator CRDs are cluster-scoped and survive Helm uninstall.
# They're harmless (no cost) but we clean them for a pristine state.
echo ""
echo "[10/11] Cleaning up Prometheus CRDs..."
if kubectl cluster-info &>/dev/null; then
  kubectl delete crd alertmanagerconfigs.monitoring.coreos.com 2>/dev/null || true
  kubectl delete crd alertmanagers.monitoring.coreos.com 2>/dev/null || true
  kubectl delete crd podmonitors.monitoring.coreos.com 2>/dev/null || true
  kubectl delete crd probes.monitoring.coreos.com 2>/dev/null || true
  kubectl delete crd prometheusagents.monitoring.coreos.com 2>/dev/null || true
  kubectl delete crd prometheuses.monitoring.coreos.com 2>/dev/null || true
  kubectl delete crd prometheusrules.monitoring.coreos.com 2>/dev/null || true
  kubectl delete crd scrapeconfigs.monitoring.coreos.com 2>/dev/null || true
  kubectl delete crd servicemonitors.monitoring.coreos.com 2>/dev/null || true
  kubectl delete crd thanosrulers.monitoring.coreos.com 2>/dev/null || true
  echo "  CRDs cleaned."
else
  echo "  Cluster already destroyed. CRDs removed with it."
fi

echo ""
echo "============================================"
echo "  [11/11] VERIFYING CLEANUP"
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