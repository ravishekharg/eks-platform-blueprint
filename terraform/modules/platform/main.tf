# Composition module: one call creates a whole environment (network → cluster → Karpenter).
# Environments differ only in the inputs they pass (see terraform/envs/*), so dev and prod
# can't drift apart structurally, and a module version can be promoted dev → prod.

module "vpc" {
  source                   = "../vpc"
  name                     = var.name
  cluster_name             = var.name
  cidr                     = var.vpc_cidr
  azs                      = var.azs
  single_nat_gateway       = var.single_nat_gateway
  flow_logs_retention_days = var.flow_logs_retention_days
  tags                     = var.tags
}

module "eks" {
  source                = "../eks"
  cluster_name          = var.name
  kubernetes_version    = var.kubernetes_version
  subnet_ids            = module.vpc.private_subnet_ids
  public_access_cidrs   = var.public_access_cidrs
  access_entries        = var.access_entries
  system_instance_types = var.system_instance_types
  system_node_count     = var.system_node_count
  tags                  = var.tags
}

module "karpenter" {
  source                    = "../karpenter"
  cluster_name              = module.eks.cluster_name
  pod_identity_trust_policy = module.eks.pod_identity_trust_policy
  tags                      = var.tags
}

# Karpenter's EC2NodeClass selects security groups by this tag; the cluster security group
# already allows node ↔ control plane traffic.
resource "aws_ec2_tag" "karpenter_discovery" {
  resource_id = module.eks.cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = module.eks.cluster_name
}
