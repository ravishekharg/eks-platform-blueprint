module "platform" {
  source = "../../modules/platform"

  name                = "blueprint-${var.environment}"
  vpc_cidr            = var.vpc_cidr
  azs                 = var.azs
  single_nat_gateway  = var.single_nat_gateway
  kubernetes_version  = var.kubernetes_version
  public_access_cidrs = var.public_access_cidrs
  system_node_count   = var.system_node_count
  access_entries      = var.access_entries
}

output "cluster_name" {
  value = module.platform.cluster_name
}

output "kubeconfig_command" {
  value = module.platform.kubeconfig_command
}

output "karpenter_node_role_name" {
  value = module.platform.karpenter_node_role_name
}

output "karpenter_interruption_queue" {
  value = module.platform.karpenter_interruption_queue
}

output "nat_public_ips" {
  value = module.platform.nat_public_ips
}
