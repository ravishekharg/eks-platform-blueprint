variable "cluster_name" {
  type = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version. Upgrade one minor version at a time (see docs/runbooks/eks-upgrade.md)."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the control plane ENIs and the system node group."
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Empty list = private endpoint only."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Don't open the Kubernetes API to the whole internet; list your office/VPN CIDRs."
  }
}

variable "access_entries" {
  description = <<-EOT
    IAM principals allowed into the cluster. policy is an EKS access policy name such as
    AmazonEKSClusterAdminPolicy, AmazonEKSAdminPolicy, AmazonEKSEditPolicy or AmazonEKSViewPolicy.
    namespaces = [] means cluster-wide.
  EOT
  type = map(object({
    principal_arn = string
    policy        = string
    namespaces    = optional(list(string), [])
  }))
  default = {}
}

variable "system_instance_types" {
  type    = list(string)
  default = ["m6i.large"]
}

variable "system_node_count" {
  description = "Nodes in the system node group (Karpenter, CoreDNS, controllers). 2 for HA."
  type        = number
  default     = 2
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "upgrade_support_type" {
  description = "STANDARD or EXTENDED support policy at the end of a version's standard support."
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.upgrade_support_type)
    error_message = "upgrade_support_type must be STANDARD or EXTENDED."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
