# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "aws_vpc_peering_connection" "this" {
  vpc_id      = var.requester.vpc_id
  peer_vpc_id = var.accepter.vpc_id
  auto_accept = true

  tags = merge(var.tags, { Name = var.name })
}

# Every route table on both sides needs a route to the peer CIDR, including the
# Outposts and Local Zone route tables. Missing the edge route tables is the most
# common reason cross-cluster calls time out.
resource "aws_route" "requester_to_accepter" {
  for_each = var.requester.route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = var.accepter.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

resource "aws_route" "accepter_to_requester" {
  for_each = var.accepter.route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = var.requester.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}
