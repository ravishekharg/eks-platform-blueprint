# Production: 3 AZs, a NAT gateway per AZ, private API endpoint plus a tightly scoped public one,
# and no edit rights for humans: changes reach prod through Git and Argo CD.
region              = "ap-south-1"
environment         = "prod"
vpc_cidr            = "10.20.0.0/16"
azs                 = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
single_nat_gateway  = false
kubernetes_version  = "1.34"
public_access_cidrs = ["203.0.113.10/32"] # VPN egress IP only
system_node_count   = 3

access_entries = {
  platform-admins = {
    principal_arn = "arn:aws:iam::444455556666:role/AWSReservedSSO_PlatformAdmin_example"
    policy        = "AmazonEKSClusterAdminPolicy"
  }
  developers-readonly = {
    principal_arn = "arn:aws:iam::444455556666:role/AWSReservedSSO_Developer_example"
    policy        = "AmazonEKSViewPolicy"
    namespaces    = ["orders", "payments"]
  }
}
