#!/bin/bash
# ============================================================================
# destroy.sh — Clean teardown of the retail-store EKS cluster
# Version: 5 (encodes lessons from session 2026-05-27)
#
# Handles:
# - Failed Helm releases (helm uninstalls before terraform destroy attempts)
# - Manually-applied AWS resources (the SG rule for Istio webhook port 15017)
# - Orphaned NLBs, target groups, security groups, ENIs blocking VPC deletion
# - Stuck namespaces with finalizers
# - Pyrra CRDs that block namespace deletion
# - Terraform state with broken Helm provider references
# - Cluster takes a few minutes to finish background cleanup after terraform exits
#
# Usage:
#   cd ~/projects/retail-store/retail-store-infra/terraform/environments/dev
#   bash ../../../destroy.sh
#
# Costs preserved (intentional):
# - AWS Secrets Manager secrets ($1.60/month total for 4 secrets)
# - S3 bucket and DynamoDB table for terraform state (~pennies)
# - ECR repositories (force_delete is true, images wiped on destroy)
# ============================================================================

set -u  # exit on undefined variable (but NOT on errors — we tolerate many)

# ────────────────────────────────────────────────────────────────────────────
# CONFIG — adjust these if your setup differs
# ────────────────────────────────────────────────────────────────────────────
REGION="${REGION:-ap-southeast-2}"
CLUSTER_NAME="${CLUSTER_NAME:-retail-store-dev}"
TERRAFORM_DIR="${TERRAFORM_DIR:-$HOME/projects/retail-store/retail-store-infra/terraform/environments/dev}"

# Colors for readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
warn()   { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $*"; }
err()    { echo -e "${RED}[$(date +%H:%M:%S)] ERR:${NC}  $*"; }
ok()     { echo -e "${GREEN}[$(date +%H:%M:%S)] OK:${NC}   $*"; }
step()   { echo ""; echo -e "${BLUE}========================================${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}========================================${NC}"; }

# ────────────────────────────────────────────────────────────────────────────
# Confirmation
# ────────────────────────────────────────────────────────────────────────────
step "Destroy confirmation"
echo "This will TEAR DOWN cluster '$CLUSTER_NAME' in region '$REGION'."
echo "It will destroy:"
echo "  - EKS cluster + node group"
echo "  - VPC + subnets + NAT gateway + EIPs"
echo "  - All Helm releases (ArgoCD, kube-prometheus-stack, Istio, etc.)"
echo "  - ECR images (force_delete=true on the repos)"
echo "  - Manually-applied AWS resources (SG rules for Istio webhook)"
echo ""
echo "It will PRESERVE:"
echo "  - AWS Secrets Manager secrets (\$1.60/month)"
echo "  - S3/DynamoDB Terraform backend state"
echo ""
read -p "Type 'destroy' to proceed: " confirm
if [ "$confirm" != "destroy" ]; then
  echo "Aborted."
  exit 0
fi

cd "$TERRAFORM_DIR" || { err "Cannot cd to $TERRAFORM_DIR"; exit 1; }
ok "Starting destroy at $(date)"

# ────────────────────────────────────────────────────────────────────────────
# Step 1: Verify kubectl context
# ────────────────────────────────────────────────────────────────────────────
step "Step 1: Verify kubectl context"
if kubectl cluster-info >/dev/null 2>&1; then
  CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "unknown")
  ok "kubectl context: $CURRENT_CTX"
else
  warn "kubectl not reachable — cluster may already be partially gone. Continuing."
fi

# ────────────────────────────────────────────────────────────────────────────
# Step 2: Pre-clean Kubernetes resources that block VPC/SG deletion
# ────────────────────────────────────────────────────────────────────────────
step "Step 2: Pre-clean Kubernetes resources"

# Delete LoadBalancer services first — these create AWS NLBs that block VPC delete
log "Deleting LoadBalancer-type Services..."
kubectl get svc -A -o json 2>/dev/null | \
  jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' | \
  while read ns name; do
    log "  Deleting service $name in $ns"
    kubectl delete svc "$name" -n "$ns" --timeout=60s --wait=false 2>/dev/null || true
  done

# Delete any Istio VirtualServices (chaos faults) before istio removal
log "Deleting any chaos VirtualServices..."
kubectl delete virtualservice --all -A --timeout=60s 2>/dev/null || true

# Delete Pyrra SLOs before destroying observability namespace
log "Deleting Pyrra SLOs..."
kubectl delete servicelevelobjective --all -A --timeout=60s 2>/dev/null || true

# Wait for LoadBalancer cleanup to begin
sleep 15
ok "Pre-clean done"

# ────────────────────────────────────────────────────────────────────────────
# Step 3: Uninstall failed Helm releases
# AWS Helm provider's bug: a release in `failed` state triggers
# destroy-then-reinstall on next terraform apply. Clean these first so
# terraform destroy gets a clean exit.
# ────────────────────────────────────────────────────────────────────────────
step "Step 3: Clean up failed Helm releases"
if command -v helm >/dev/null 2>&1; then
  FAILED_RELEASES=$(helm list -A 2>/dev/null | awk '$8=="failed"||$9=="failed" {print $1" "$2}')
  if [ -n "$FAILED_RELEASES" ]; then
    warn "Found failed Helm releases — uninstalling:"
    echo "$FAILED_RELEASES" | while read name ns; do
      log "  helm uninstall $name -n $ns"
      helm uninstall "$name" -n "$ns" 2>/dev/null || true
    done
  else
    ok "No failed Helm releases found"
  fi
else
  warn "helm CLI not available — skipping"
fi

# ────────────────────────────────────────────────────────────────────────────
# Step 4: Delete CRDs that block namespace deletion
# Pyrra CRDs, Istio CRDs, ArgoCD CRDs all have finalizers
# ────────────────────────────────────────────────────────────────────────────
step "Step 4: Clear finalizers on namespaces"

for ns in monitoring argocd istio-system ingress-nginx \
          ui-dev catalog-dev cart-dev checkout-dev orders-dev loadtest; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    log "  Removing finalizers from $ns"
    kubectl patch namespace "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
  fi
done

ok "Namespace finalizers cleared"

# ────────────────────────────────────────────────────────────────────────────
# Step 5: Get VPC ID for orphan cleanup (before terraform destroys it)
# ────────────────────────────────────────────────────────────────────────────
step "Step 5: Identify VPC for orphan cleanup"
VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || \
         aws ec2 describe-vpcs \
           --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" \
           --region "$REGION" \
           --query 'Vpcs[0].VpcId' \
           --output text 2>/dev/null || echo "")

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] && [ "$VPC_ID" != "null" ]; then
  ok "VPC ID: $VPC_ID"
else
  warn "Could not determine VPC ID — orphan cleanup will be limited"
  VPC_ID=""
fi

# ────────────────────────────────────────────────────────────────────────────
# Step 6: Delete orphaned NLBs in our VPC
# ────────────────────────────────────────────────────────────────────────────
if [ -n "$VPC_ID" ]; then
  step "Step 6: Delete orphaned load balancers"

  NLB_ARNS=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
    --output text 2>/dev/null || echo "")

  if [ -n "$NLB_ARNS" ]; then
    for arn in $NLB_ARNS; do
      log "  Deleting NLB: $arn"
      aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region "$REGION" 2>/dev/null || true
    done
    log "  Waiting 30s for NLB tear-down..."
    sleep 30
  else
    ok "No orphaned NLBs"
  fi

  # Target groups (orphaned by NLB deletion)
  TG_ARNS=$(aws elbv2 describe-target-groups \
    --region "$REGION" \
    --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" \
    --output text 2>/dev/null || echo "")

  if [ -n "$TG_ARNS" ]; then
    for arn in $TG_ARNS; do
      log "  Deleting Target Group: $arn"
      aws elbv2 delete-target-group --target-group-arn "$arn" --region "$REGION" 2>/dev/null || true
    done
  fi
fi

# ────────────────────────────────────────────────────────────────────────────
# Step 7: Remove manually-added security group rules
# Session 2026-05-27 added inbound rule for istiod webhook (port 15017)
# Terraform doesn't know about these → won't delete them → blocks SG delete
# ────────────────────────────────────────────────────────────────────────────
step "Step 7: Remove manually-added SG rules"

if [ -n "$VPC_ID" ]; then
  NODE_SGS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*node*" \
    --region "$REGION" \
    --query 'SecurityGroups[*].GroupId' \
    --output text 2>/dev/null || echo "")

  for sg in $NODE_SGS; do
    log "  Inspecting SG: $sg"
    RULES=$(aws ec2 describe-security-group-rules \
      --filters "Name=group-id,Values=$sg" \
      --region "$REGION" \
      --query "SecurityGroupRules[?IsEgress==\`false\` && FromPort==\`15017\`].SecurityGroupRuleId" \
      --output text 2>/dev/null || echo "")

    for rule in $RULES; do
      log "    Revoking rule $rule (port 15017 ingress)"
      aws ec2 revoke-security-group-ingress \
        --group-id "$sg" \
        --security-group-rule-ids "$rule" \
        --region "$REGION" 2>/dev/null || true
    done
  done
  ok "Manual SG rules cleaned"
fi

# ────────────────────────────────────────────────────────────────────────────
# Step 8: Disable ArgoCD selfHeal (so it doesn't fight us during destroy)
# ────────────────────────────────────────────────────────────────────────────
step "Step 8: Disable ArgoCD selfHeal"
kubectl get application -n argocd -o name 2>/dev/null | \
  while read app; do
    kubectl patch "$app" -n argocd \
      --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":false}}}}' 2>/dev/null || true
  done
ok "ArgoCD selfHeal disabled"

# ────────────────────────────────────────────────────────────────────────────
# Step 9: Run terraform destroy
# ────────────────────────────────────────────────────────────────────────────
step "Step 9: Run terraform destroy"
log "This takes 10-15 minutes. Walk away."
terraform destroy -auto-approve

TF_EXIT=$?
if [ $TF_EXIT -eq 0 ]; then
  ok "terraform destroy completed cleanly"
else
  err "terraform destroy exited with code $TF_EXIT — running cleanup retry"
  log "Retry with refresh first to update state..."
  terraform destroy -auto-approve -refresh=true
fi

# ────────────────────────────────────────────────────────────────────────────
# Step 10: Final orphan sweep
# Sometimes ENIs and SGs linger after destroy
# ────────────────────────────────────────────────────────────────────────────
step "Step 10: Final orphan sweep"

if [ -n "$VPC_ID" ]; then
  # Orphaned ENIs
  ENI_IDS=$(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' \
    --output text 2>/dev/null || echo "")

  for eni in $ENI_IDS; do
    log "  Deleting orphaned ENI: $eni"
    aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" 2>/dev/null || true
  done

  # Orphaned SGs (non-default)
  ORPHAN_SGS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
    --output text 2>/dev/null || echo "")

  for sg in $ORPHAN_SGS; do
    log "  Deleting orphaned SG: $sg"
    aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null || true
  done
fi

# ────────────────────────────────────────────────────────────────────────────
# Step 11: Verify nothing remains
# ────────────────────────────────────────────────────────────────────────────
step "Step 11: Verification"

CLUSTERS=$(aws eks list-clusters --region "$REGION" --query "clusters[?contains(@, '$CLUSTER_NAME')]" --output text 2>/dev/null || echo "")
if [ -n "$CLUSTERS" ]; then
  warn "EKS cluster still exists: $CLUSTERS (may be deleting in background)"
else
  ok "No EKS clusters remain"
fi

NAT_COUNT=$(aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available,pending" \
  --region "$REGION" \
  --query 'length(NatGateways[])' \
  --output text 2>/dev/null || echo "0")
if [ "$NAT_COUNT" != "0" ]; then
  warn "$NAT_COUNT NAT gateway(s) still active (\$0.045/hr each)"
else
  ok "No active NAT gateways"
fi

EIP_COUNT=$(aws ec2 describe-addresses --region "$REGION" --query 'length(Addresses[])' --output text 2>/dev/null || echo "0")
if [ "$EIP_COUNT" != "0" ]; then
  warn "$EIP_COUNT Elastic IP(s) still allocated (\$0.005/hr each unassociated)"
else
  ok "No Elastic IPs"
fi

LB_COUNT=$(aws elbv2 describe-load-balancers --region "$REGION" --query 'length(LoadBalancers[])' --output text 2>/dev/null || echo "0")
if [ "$LB_COUNT" != "0" ]; then
  warn "$LB_COUNT load balancer(s) still exist"
else
  ok "No load balancers"
fi

step "Destroy complete"
echo ""
echo "Remaining costs (intentional):"
echo "  - 4 Secrets Manager secrets: ~\$1.60/month"
echo "  - S3 + DynamoDB for terraform state: ~pennies/month"
echo ""
echo "If warnings appeared above, give AWS ~5 minutes to finish background"
echo "deletes, then re-run this script — it's idempotent."
echo ""
ok "Done at $(date)"

