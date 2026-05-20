#!/usr/bin/env bash
# destroy.sh - Tear down retail-store EKS cluster cleanly
# v4: Proactive Helm cleanup + namespace finalizer clearing + state cleanup
#     before terraform destroy. Encodes lessons from real destroy failures
#     where helm uninstall on kube-prometheus-stack hung for 10+ min.
#
# Place this in: ~/projects/retail-store/retail-store-infra/destroy.sh
# Usage:         ./destroy.sh
#
# Environment overrides (optional):
#   CLUSTER_NAME (default: retail-store-dev)
#   AWS_REGION   (default: ap-southeast-2)
#   TF_DIR       (default: terraform/environments/dev)

set -uo pipefail   # NOT -e — we want cleanup to continue past individual failures

# =====================================================================
# Disable AWS CLI v2 pager (this is what makes you press 'q' on every
# `aws ec2 describe-*` call). Setting AWS_PAGER="" turns it off globally
# for this shell. PAGER="" catches anything else that might paginate.
# =====================================================================
export AWS_PAGER=""
export PAGER=""

# =====================================================================
# Configuration
# =====================================================================
CLUSTER_NAME="${CLUSTER_NAME:-retail-store-dev}"
AWS_REGION="${AWS_REGION:-ap-southeast-2}"
TF_DIR="${TF_DIR:-terraform/environments/dev}"

# Helm releases that are heavy/fragile during uninstall.
# These get force-uninstalled BEFORE terraform destroy to avoid timeouts.
HEAVY_RELEASES=(
  "kube-prometheus-stack:monitoring"
  "pyrra:monitoring"
  "argocd:argocd"
  "argocd-image-updater:argocd"
  "nginx-external:ingress-nginx"
  "aws-load-balancer-controller:kube-system"
  "metrics-server:kube-system"
)

# Namespaces that often get stuck terminating due to CRD finalizers.
STUCK_NAMESPACES=("monitoring" "argocd" "ingress-nginx")

# Colors for readable output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} ${BOLD}$1${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; }

log "=========================================="
log "  RETAIL-STORE EKS DESTROY (v4)"
log "  Cluster: ${CLUSTER_NAME}"
log "  Region:  ${AWS_REGION}"
log "  TF dir:  ${TF_DIR}"
log "=========================================="
echo ""

# =====================================================================
# STEP 1 — Capture VPC ID from Terraform state
# =====================================================================
log "Step 1: Capturing VPC ID from Terraform state..."

if [ ! -d "${TF_DIR}" ]; then
  err "Terraform directory not found: ${TF_DIR}"
  err "Run this script from the repo root, or set TF_DIR=<path>"
  exit 1
fi

cd "${TF_DIR}"
VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "")
cd - > /dev/null

if [ -z "${VPC_ID}" ]; then
  warn "No VPC ID in Terraform state - already destroyed or apply never ran"
else
  ok "VPC ID captured: ${VPC_ID}"
fi
echo ""

# =====================================================================
# STEP 2 — Pre-clean Kubernetes resources (SLOs + PVCs)
# =====================================================================
log "Step 2: Pre-cleaning Kubernetes resources..."

if kubectl cluster-info &>/dev/null; then

  log "  → Deleting Pyrra SLO custom resources..."
  if kubectl delete slo --all -A --timeout=60s &>/dev/null; then
    ok "SLOs deleted"
  else
    warn "No SLOs to delete (or already gone)"
  fi

  log "  → Deleting all PVCs (releases EBS volumes via CSI driver)..."
  PVC_NAMESPACES=$(kubectl get pvc -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u)
  if [ -n "${PVC_NAMESPACES}" ]; then
    for ns in ${PVC_NAMESPACES}; do
      log "    Namespace: ${ns}"
      kubectl delete pvc --all -n "$ns" --timeout=60s 2>/dev/null || true
    done
    log "  → Waiting 30s for EBS CSI driver to delete volumes in AWS..."
    sleep 30
    ok "PVCs released"
  else
    ok "No PVCs found"
  fi

else
  warn "kubectl can't reach cluster - skipping K8s pre-clean"
fi
echo ""

# =====================================================================
# STEP 2.5 — NEW IN V4: Proactive Helm release force-uninstall
#
# Why this exists:
#   terraform destroy calls `helm uninstall` for each helm_release.
#   For heavy charts (kube-prometheus-stack with ~30 CRDs, argocd, etc.)
#   that uninstall can take 10+ minutes due to CRD finalizers and
#   pre-delete hooks racing with admission webhook deletion. When it
#   exceeds the helm provider timeout, terraform destroy errors out and
#   never proceeds to destroy EKS, leaving the cluster alive.
#
# What this step does:
#   Force-uninstalls each heavy release with --no-hooks and a short
#   timeout. Skips finalizer waits and webhook races. Then clears
#   stuck namespace finalizers via the /finalize subresource.
# =====================================================================
log "Step 2.5: Proactive Helm release force-uninstall..."

if kubectl cluster-info &>/dev/null; then

  for entry in "${HEAVY_RELEASES[@]}"; do
    name="${entry%%:*}"
    ns="${entry##*:}"

    if helm status "$name" -n "$ns" &>/dev/null; then
      log "  → Force-uninstalling $name in namespace $ns..."
      if helm uninstall "$name" -n "$ns" --no-hooks --timeout 60s 2>/dev/null; then
        ok "Uninstalled $name"
      else
        warn "$name uninstall failed or timed out — terraform will retry"
      fi
    fi
  done

  log "  → Clearing finalizers on stuck namespaces..."
  for ns in "${STUCK_NAMESPACES[@]}"; do
    if kubectl get namespace "$ns" &>/dev/null; then
      kubectl get namespace "$ns" -o json 2>/dev/null | \
        jq '.spec.finalizers = [] | .metadata.finalizers = []' | \
        kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - &>/dev/null && \
        ok "Finalizers cleared on namespace $ns" || \
        warn "Could not clear finalizers on $ns (may not need it)"
    fi
  done

else
  warn "kubectl can't reach cluster - skipping Helm/finalizer cleanup"
fi
echo ""

# =====================================================================
# STEP 3 — Pre-clean orphaned AWS resources (only if VPC_ID known)
# =====================================================================
if [ -n "${VPC_ID}" ]; then
  log "Step 3: Pre-cleaning orphaned AWS resources in ${VPC_ID}..."

  log "  → Looking for orphaned NLBs..."
  NLB_ARNS=$(aws elbv2 describe-load-balancers \
    --region "${AWS_REGION}" \
    --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" \
    --output text 2>/dev/null || echo "")

  if [ -n "${NLB_ARNS}" ]; then
    for arn in ${NLB_ARNS}; do
      log "    Deleting NLB: ${arn##*/}"
      aws elbv2 delete-load-balancer \
        --region "${AWS_REGION}" \
        --load-balancer-arn "$arn" 2>/dev/null \
        && ok "NLB deleted" \
        || warn "NLB delete failed (continuing)"
    done
    log "  → Waiting 60s for NLB deletion to propagate (releases ENIs)..."
    sleep 60
  else
    ok "No orphaned NLBs"
  fi

  log "  → Looking for orphaned target groups..."
  TG_ARNS=$(aws elbv2 describe-target-groups \
    --region "${AWS_REGION}" \
    --query "TargetGroups[?VpcId=='${VPC_ID}'].TargetGroupArn" \
    --output text 2>/dev/null || echo "")

  if [ -n "${TG_ARNS}" ]; then
    for arn in ${TG_ARNS}; do
      aws elbv2 delete-target-group \
        --region "${AWS_REGION}" \
        --target-group-arn "$arn" 2>/dev/null \
        && ok "Target group deleted: ${arn##*/}" \
        || warn "TG delete failed"
    done
  else
    ok "No orphaned target groups"
  fi

  log "  → Looking for orphaned network interfaces..."
  ENI_IDS=$(aws ec2 describe-network-interfaces \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=status,Values=available" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' \
    --output text 2>/dev/null || echo "")

  if [ -n "${ENI_IDS}" ]; then
    for eni in ${ENI_IDS}; do
      aws ec2 delete-network-interface \
        --region "${AWS_REGION}" \
        --network-interface-id "$eni" 2>/dev/null \
        && ok "ENI ${eni} deleted" \
        || warn "ENI ${eni} delete failed"
    done
  else
    ok "No orphaned ENIs"
  fi

  log "  → Looking for orphaned security groups..."
  SG_IDS=$(aws ec2 describe-security-groups \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text 2>/dev/null || echo "")

  if [ -n "${SG_IDS}" ]; then
    log "    Pass 1: Revoking all SG rules (breaks circular refs)..."
    for sg in ${SG_IDS}; do
      INGRESS=$(aws ec2 describe-security-groups \
        --region "${AWS_REGION}" --group-ids "$sg" \
        --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
      if [ "$INGRESS" != "[]" ] && [ -n "$INGRESS" ]; then
        aws ec2 revoke-security-group-ingress \
          --region "${AWS_REGION}" --group-id "$sg" \
          --ip-permissions "$INGRESS" 2>/dev/null || true
      fi

      EGRESS=$(aws ec2 describe-security-groups \
        --region "${AWS_REGION}" --group-ids "$sg" \
        --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)
      if [ "$EGRESS" != "[]" ] && [ -n "$EGRESS" ]; then
        aws ec2 revoke-security-group-egress \
          --region "${AWS_REGION}" --group-id "$sg" \
          --ip-permissions "$EGRESS" 2>/dev/null || true
      fi
    done

    log "    Pass 2: Deleting security groups..."
    for sg in ${SG_IDS}; do
      aws ec2 delete-security-group \
        --region "${AWS_REGION}" --group-id "$sg" 2>/dev/null \
        && ok "SG ${sg} deleted" \
        || warn "SG ${sg} - terraform destroy may handle it"
    done
  else
    ok "No non-default security groups"
  fi

else
  log "Step 3: Skipped (no VPC ID)"
fi
echo ""

# =====================================================================
# STEP 3.5 — NEW IN V4: Remove already-uninstalled Helm releases
#              and stuck Kubernetes resources from Terraform state
#
# Why this exists:
#   After Step 2.5 force-uninstalled the Helm releases, Terraform may
#   still try to manage them and hang trying to confirm deletion. Same
#   for Kubernetes namespaces stuck on finalizers.
# =====================================================================
log "Step 3.5: Removing already-cleaned resources from Terraform state..."

cd "${TF_DIR}"

HELM_RESOURCES=$(terraform state list 2>/dev/null | grep "helm_release" || echo "")
if [ -n "${HELM_RESOURCES}" ]; then
  while IFS= read -r resource; do
    log "  → terraform state rm $resource"
    terraform state rm "$resource" &>/dev/null \
      && ok "Removed from state" \
      || warn "Could not remove (may already be gone)"
  done <<< "${HELM_RESOURCES}"
else
  ok "No helm_release resources in Terraform state"
fi

K8S_NS_RESOURCES=$(terraform state list 2>/dev/null | grep "kubernetes_namespace" || echo "")
if [ -n "${K8S_NS_RESOURCES}" ]; then
  while IFS= read -r resource; do
    log "  → terraform state rm $resource"
    terraform state rm "$resource" &>/dev/null \
      && ok "Removed namespace from state" \
      || warn "Could not remove namespace from state"
  done <<< "${K8S_NS_RESOURCES}"
fi

cd - > /dev/null
echo ""

# =====================================================================
# STEP 4 — terraform destroy (auto-approved, no pager)
# =====================================================================
log "Step 4: Running terraform destroy (auto-approved)..."
log "  Expected duration: 8-12 minutes (faster after pre-cleanup)."
echo ""

cd "${TF_DIR}"

terraform destroy -auto-approve 2>&1 | tee /tmp/terraform-destroy.log
DESTROY_EXIT=${PIPESTATUS[0]}

cd - > /dev/null

if [ "${DESTROY_EXIT}" -eq 0 ]; then
  ok "terraform destroy succeeded"
else
  warn "terraform destroy exited with ${DESTROY_EXIT}"
  warn "Continuing with post-destroy verification..."
fi
echo ""

# =====================================================================
# STEP 5 — Post-destroy: clean orphaned EBS volumes
# =====================================================================
log "Step 5: Cleaning orphaned EBS volumes..."

ORPHAN_VOLS_NEW=$(aws ec2 describe-volumes \
  --region "${AWS_REGION}" \
  --filters \
    "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
    "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' \
  --output text 2>/dev/null || echo "")

ORPHAN_VOLS_LEGACY=$(aws ec2 describe-volumes \
  --region "${AWS_REGION}" \
  --filters \
    "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" \
    "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' \
  --output text 2>/dev/null || echo "")

ORPHAN_VOLS_CSI=$(aws ec2 describe-volumes \
  --region "${AWS_REGION}" \
  --filters \
    "Name=tag-key,Values=CSIVolumeName" \
    "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' \
  --output text 2>/dev/null || echo "")

ALL_ORPHANS=$(echo "${ORPHAN_VOLS_NEW} ${ORPHAN_VOLS_LEGACY} ${ORPHAN_VOLS_CSI}" \
  | tr ' ' '\n' | grep -v '^$' | sort -u)

if [ -z "${ALL_ORPHANS}" ]; then
  ok "No orphaned EBS volumes found"
else
  ORPHAN_COUNT=$(echo "${ALL_ORPHANS}" | wc -l)
  warn "Found ${ORPHAN_COUNT} orphaned EBS volume(s)"
  for vol in ${ALL_ORPHANS}; do
    log "  → Deleting orphaned volume: ${vol}"
    aws ec2 delete-volume \
      --region "${AWS_REGION}" \
      --volume-id "$vol" 2>/dev/null \
      && ok "Deleted ${vol}" \
      || err "Failed to delete ${vol} (may need manual cleanup)"
  done
fi
echo ""

# =====================================================================
# STEP 6 — Final verification
# =====================================================================
log "Step 6: Verifying clean state..."

CLUSTERS=$(aws eks list-clusters --region "${AWS_REGION}" \
  --query 'clusters' --output text 2>/dev/null || echo "")
if echo "${CLUSTERS}" | grep -q "${CLUSTER_NAME}" 2>/dev/null; then
  err "EKS cluster ${CLUSTER_NAME} still exists!"
else
  ok "No EKS clusters remaining"
fi

LB_COUNT=$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
  --query 'length(LoadBalancers)' --output text 2>/dev/null || echo "0")
ok "Load balancers in region: ${LB_COUNT}"

NAT_COUNT=$(aws ec2 describe-nat-gateways --region "${AWS_REGION}" \
  --filter "Name=state,Values=available" \
  --query 'length(NatGateways)' --output text 2>/dev/null || echo "0")
ok "Active NAT gateways: ${NAT_COUNT}"

EIP_COUNT=$(aws ec2 describe-addresses --region "${AWS_REGION}" \
  --query 'length(Addresses)' --output text 2>/dev/null || echo "0")
if [ "${EIP_COUNT}" != "0" ]; then
  warn "Elastic IPs: ${EIP_COUNT} (these incur charges if unattached!)"
else
  ok "Elastic IPs: 0"
fi

REMAINING_VOLS=$(aws ec2 describe-volumes \
  --region "${AWS_REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
  --query 'length(Volumes)' --output text 2>/dev/null || echo "0")
if [ "${REMAINING_VOLS}" != "0" ]; then
  warn "EBS volumes still tagged for cluster: ${REMAINING_VOLS}"
else
  ok "EBS volumes tagged for cluster: 0"
fi

echo ""
log "=========================================="
log "  DESTROY COMPLETE"
log "=========================================="
echo ""
log "Persistent resources (NOT destroyed by this script):"
log "  - AWS Secrets Manager secrets (~\$1.60/month for 4 secrets):"
log "      retail-store/github-pat"
log "      retail-store/grafana-admin"
log "      retail-store/slack-webhook"
log "      retail-store/pagerduty-key"
log "  - Terraform state bucket (S3) + lock table (DynamoDB)"
log ""
log "If you see warnings above (NLBs, ENIs, SGs), re-run this script."
log "Most stragglers clear on a second pass."