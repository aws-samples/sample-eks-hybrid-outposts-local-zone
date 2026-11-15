# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Offline unit tests: the AWS provider is mocked, nothing is created.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:111122223333:log-group:/aws/vpc/test/flow-logs" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/test-flowlogs" }
  }
}

variables {
  name       = "test-outposts"
  cidr_block = "10.0.0.0/16"
  regional_subnets = [
    { cidr = "10.0.1.0/24", availability_zone = "us-east-1a" },
    { cidr = "10.0.2.0/24", availability_zone = "us-east-1b" },
  ]
  edge_type              = "outposts"
  edge_subnet_cidr       = "10.0.10.0/24"
  edge_availability_zone = "us-east-1a"
  outpost_arn            = "arn:aws:outposts:us-east-1:111122223333:outpost/op-0123456789abcdef0"
}

run "outposts_edge_subnet_is_on_the_rack" {
  command = apply

  assert {
    condition     = aws_subnet.edge.outpost_arn == var.outpost_arn
    error_message = "The edge subnet must be created on the Outposts."
  }

  assert {
    condition     = aws_subnet.edge.availability_zone == "us-east-1a"
    error_message = "The edge subnet must be in the Outposts Availability Zone."
  }
}

run "edge_subnet_has_no_load_balancer_tags" {
  command = apply

  assert {
    condition     = !contains(keys(aws_subnet.edge.tags), "kubernetes.io/role/internal-elb") && !contains(keys(aws_subnet.edge.tags), "kubernetes.io/role/elb")
    error_message = "NLBs are not supported on Outposts subnets; the edge subnet must not carry ELB discovery tags."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.regional : s.tags["kubernetes.io/role/internal-elb"] == "1" && s.tags["kubernetes.io/role/elb"] == "1"])
    error_message = "Regional subnets must carry both ELB discovery tags."
  }
}

run "no_public_ips_on_launch" {
  command = apply

  assert {
    condition     = alltrue(concat([for s in aws_subnet.regional : !s.map_public_ip_on_launch], [!aws_subnet.edge.map_public_ip_on_launch]))
    error_message = "No subnet should assign public IPs at launch."
  }
}

run "edge_traffic_egresses_through_nat" {
  command = apply

  assert {
    condition     = aws_route.edge_default.nat_gateway_id == aws_nat_gateway.this.id && aws_route.edge_default.destination_cidr_block == "0.0.0.0/0"
    error_message = "The edge route table must default to the NAT gateway."
  }

  assert {
    condition     = aws_nat_gateway.this.subnet_id == aws_subnet.regional[0].id
    error_message = "The NAT gateway must live in a regional subnet."
  }

  assert {
    condition     = toset(keys(output.route_table_ids)) == toset(["regional", "edge"])
    error_message = "route_table_ids must expose static keys for for_each in the peering module."
  }
}

run "flow_logs_enabled_by_default" {
  command = apply

  assert {
    condition     = length(aws_flow_log.this) == 1 && aws_flow_log.this[0].traffic_type == "ALL"
    error_message = "Flow logs must be enabled by default and capture ALL traffic."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 365
    error_message = "Flow log retention should default to 365 days."
  }
}

run "flow_logs_can_be_disabled" {
  command = apply

  variables {
    flow_logs = { enabled = false }
  }

  assert {
    condition     = length(aws_flow_log.this) == 0 && length(aws_iam_role.flow_logs) == 0
    error_message = "Disabling flow logs must remove the flow log and its IAM role."
  }
}

run "local_zone_subnet" {
  command = apply

  variables {
    name                   = "test-localzone"
    edge_type              = "localzone"
    edge_availability_zone = "us-east-1-mia-2"
    outpost_arn            = null
  }

  assert {
    condition     = aws_subnet.edge.availability_zone == "us-east-1-mia-2" && aws_subnet.edge.tags["edge-mesh:edge-type"] == "localzone"
    error_message = "The Local Zone subnet must be placed in the Local Zone."
  }
}

run "rejects_outposts_without_arn" {
  command = plan

  variables {
    outpost_arn = null
  }

  expect_failures = [var.outpost_arn]
}

run "rejects_local_zone_with_outpost_arn" {
  command = plan

  variables {
    edge_type = "localzone"
  }

  expect_failures = [var.outpost_arn]
}

run "rejects_regional_subnets_in_one_az" {
  command = plan

  variables {
    regional_subnets = [
      { cidr = "10.0.1.0/24", availability_zone = "us-east-1a" },
      { cidr = "10.0.2.0/24", availability_zone = "us-east-1a" },
    ]
  }

  expect_failures = [var.regional_subnets]
}

run "rejects_unknown_edge_type" {
  command = plan

  variables {
    edge_type = "wavelength"
  }

  expect_failures = [var.edge_type]
}
