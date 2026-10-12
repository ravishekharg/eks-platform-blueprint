variable "cluster_name" {
  type = string
}

variable "namespace" {
  description = "Namespace Argo CD installs the Karpenter controller into."
  type        = string
  default     = "kube-system"
}

variable "pod_identity_trust_policy" {
  description = "Trust policy for EKS Pod Identity roles (output of the eks module)."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
