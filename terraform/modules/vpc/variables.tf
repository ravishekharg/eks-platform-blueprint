variable "name" {
  description = "Name prefix for every resource."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster that will use this VPC (used for Karpenter subnet discovery tags)."
  type        = string
}

variable "cidr" {
  description = "VPC CIDR. A /16 leaves room for /19 private subnets per AZ."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) <= 16
    error_message = "cidr must be a valid IPv4 CIDR of /16 or larger (pods take one VPC IP each)."
  }
}

variable "azs" {
  description = "Availability zones to use (2 for non-production, 3 for production)."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2 && length(var.azs) <= 4
    error_message = "Use between 2 and 4 availability zones."
  }
}

variable "single_nat_gateway" {
  description = "One NAT gateway for all AZs (cheaper, but an AZ outage removes egress). Use false in production."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "Retention for VPC flow logs in CloudWatch. 0 disables flow logs."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default     = {}
}
