# Non-production: 2 AZs and one NAT gateway to keep the bill small.
region              = "ap-south-1"
environment         = "dev"
vpc_cidr            = "10.10.0.0/16"
azs                 = ["ap-south-1a", "ap-south-1b"]
single_nat_gateway  = true
kubernetes_version  = "1.34"
public_access_cidrs = ["203.0.113.0/24"] # replace with your office/VPN range
system_node_count   = 2

access_entries = {
  platform-admins = {
    principal_arn = "arn:aws:iam::111122223333:role/AWSReservedSSO_PlatformAdmin_example"
    policy        = "AmazonEKSClusterAdminPolicy"
  }
  developers = {
    principal_arn = "arn:aws:iam::111122223333:role/AWSReservedSSO_Developer_example"
    policy        = "AmazonEKSEditPolicy"
    namespaces    = ["orders", "payments"]
  }
}
