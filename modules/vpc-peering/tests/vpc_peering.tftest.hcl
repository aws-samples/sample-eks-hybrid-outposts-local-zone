# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

mock_provider "aws" {}

variables {
  name = "test-peering"
  requester = {
    vpc_id          = "vpc-0aaaaaaaaaaaaaaaa"
    cidr            = "10.0.0.0/16"
    route_table_ids = { regional = "rtb-0a00000000000001", edge = "rtb-0a00000000000002" }
  }
  accepter = {
    vpc_id          = "vpc-0bbbbbbbbbbbbbbbb"
    cidr            = "10.1.0.0/16"
    route_table_ids = { regional = "rtb-0b00000000000001", edge = "rtb-0b00000000000002" }
  }
}

run "routes_every_route_table_in_both_directions" {
  command = apply

  assert {
    condition     = output.route_count == 4
    error_message = "Expected one route per route table on each side (4 total)."
  }

  assert {
    condition     = aws_route.requester_to_accepter["edge"].destination_cidr_block == "10.1.0.0/16"
    error_message = "The Outposts edge route table must route the Local Zone VPC CIDR to the peering connection."
  }

  assert {
    condition     = aws_route.accepter_to_requester["edge"].destination_cidr_block == "10.0.0.0/16"
    error_message = "The Local Zone edge route table must route the Outposts VPC CIDR to the peering connection."
  }

  assert {
    condition     = alltrue([for r in concat(values(aws_route.requester_to_accepter), values(aws_route.accepter_to_requester)) : r.vpc_peering_connection_id == aws_vpc_peering_connection.this.id])
    error_message = "All routes must target the peering connection."
  }
}

run "peering_is_auto_accepted" {
  command = apply

  assert {
    condition     = aws_vpc_peering_connection.this.auto_accept
    error_message = "Same-account peering should be auto-accepted."
  }
}

run "rejects_overlapping_cidrs" {
  command = plan

  variables {
    accepter = {
      vpc_id          = "vpc-0bbbbbbbbbbbbbbbb"
      cidr            = "10.0.0.0/16"
      route_table_ids = { regional = "rtb-0b00000000000001" }
    }
  }

  expect_failures = [var.accepter]
}
