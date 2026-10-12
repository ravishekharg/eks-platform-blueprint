variable "region" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "single_nat_gateway" {
  type = bool
}

variable "kubernetes_version" {
  type = string
}

variable "public_access_cidrs" {
  type = list(string)
}

variable "system_node_count" {
  type = number
}

variable "access_entries" {
  type = map(object({
    principal_arn = string
    policy        = string
    namespaces    = optional(list(string), [])
  }))
  default = {}
}
