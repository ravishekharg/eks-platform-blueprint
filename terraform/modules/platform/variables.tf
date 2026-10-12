variable "name" {
  description = "Environment/cluster name, e.g. blueprint-dev."
  type        = string
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "single_nat_gateway" {
  type    = bool
  default = false
}

variable "flow_logs_retention_days" {
  type    = number
  default = 30
}

variable "kubernetes_version" {
  type = string
}

variable "public_access_cidrs" {
  type    = list(string)
  default = []
}

variable "access_entries" {
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
  type    = number
  default = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}
