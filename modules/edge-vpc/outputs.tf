# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "regional_subnet_ids" {
  description = "IDs of the two regional subnets (EKS control plane ENIs, NAT gateway)."
  value       = aws_subnet.regional[*].id
}

output "edge_subnet_id" {
  description = "ID of the edge subnet (Outposts or Local Zone) that hosts the worker nodes."
  value       = aws_subnet.edge.id
}

output "edge_subnet_cidr" {
  description = "CIDR block of the edge subnet."
  value       = aws_subnet.edge.cidr_block
}

output "route_table_ids" {
  description = "Route table IDs keyed by role. Keys are static so callers can use them in for_each."
  value = {
    regional = aws_route_table.regional.id
    edge     = aws_route_table.edge.id
  }
}

output "nat_public_ip" {
  description = "Public IP of the NAT gateway. Cross-cluster calls to the peer EKS public endpoint originate from this address."
  value       = aws_eip.nat.public_ip
}
