
#
# Anything that runs an admission webhook on worker nodes (Istio sidecar
# injector on 15017, cert-manager, External Secrets Operator, OPA Gatekeeper,
# future tooling) needs ingress from the cluster SG to the node SG.
#
# Rather than authorize each port individually as we add tooling, open the
# ephemeral port range to the cluster SG. Source restriction means only the
# EKS control plane (not the public internet, not other pods) can use it.
#
# Symptom this rule prevents:
#   "failed calling webhook X: context deadline exceeded"
#   while pod-to-pod curl within the cluster works fine.
# =============================================================================

resource "aws_security_group_rule" "cluster_to_node_webhooks" {
  description              = "Allow EKS control plane to reach webhook services on worker nodes"
  type                     = "ingress"
  from_port                = 1024
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = module.eks.cluster_security_group_id
  security_group_id        = module.eks.node_security_group_id
}