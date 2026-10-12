output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = [for az in var.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  value = [for az in var.azs : aws_subnet.private[az].id]
}

output "nat_public_ips" {
  description = "Stable egress IPs: give these to partners who allow-list by IP."
  value       = [for eip in aws_eip.nat : eip.public_ip]
}
