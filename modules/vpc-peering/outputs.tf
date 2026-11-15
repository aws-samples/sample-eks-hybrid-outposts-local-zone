# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "id" {
  description = "ID of the VPC peering connection."
  value       = aws_vpc_peering_connection.this.id
}

output "route_count" {
  description = "Number of routes created across both VPCs."
  value       = length(aws_route.requester_to_accepter) + length(aws_route.accepter_to_requester)
}
