# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  is_outposts = var.edge_type == "outposts"
  tags        = merge(var.tags, { "edge-mesh:vpc" = var.name })

  # Regional subnets carry both ELB discovery tags. The edge subnet carries none:
  # Network Load Balancers are not supported on Outposts subnets, and the AWS Load
  # Balancer Controller would otherwise try to place one there.
  regional_subnet_tags = {
    "kubernetes.io/role/elb"          = "1"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name })
}

# Removes all rules from the default security group so nothing can use it by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-default-deny" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = var.name })
}

resource "aws_subnet" "regional" {
  count = length(var.regional_subnets)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.regional_subnets[count.index].cidr
  availability_zone       = var.regional_subnets[count.index].availability_zone
  map_public_ip_on_launch = false

  tags = merge(local.tags, local.regional_subnet_tags, {
    Name             = "${var.name}-regional-${count.index + 1}"
    "edge-mesh:tier" = "regional"
  })
}

resource "aws_subnet" "edge" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.edge_subnet_cidr
  availability_zone       = var.edge_availability_zone
  outpost_arn             = local.is_outposts ? var.outpost_arn : null
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name                  = "${var.name}-${var.edge_type}"
    "edge-mesh:tier"      = "edge"
    "edge-mesh:edge-type" = var.edge_type
  })
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.name}-nat" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.regional[0].id
  tags          = merge(local.tags, { Name = var.name })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "regional" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-regional" })
}

resource "aws_route" "regional_default" {
  route_table_id         = aws_route_table.regional.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "regional" {
  count = length(aws_subnet.regional)

  subnet_id      = aws_subnet.regional[count.index].id
  route_table_id = aws_route_table.regional.id
}

resource "aws_route_table" "edge" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-${var.edge_type}" })
}

resource "aws_route" "edge_default" {
  route_table_id         = aws_route_table.edge.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "edge" {
  subnet_id      = aws_subnet.edge.id
  route_table_id = aws_route_table.edge.id
}

# ---------------------------------------------------------------------------
# VPC Flow Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.flow_logs.enabled ? 1 : 0

  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_logs.retention_days
  kms_key_id        = var.flow_logs.kms_key_arn
  tags              = local.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  count = var.flow_logs.enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.flow_logs.enabled ? 1 : 0

  name_prefix        = "${substr(var.name, 0, 20)}-flowlogs-"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json
  tags               = local.tags
}

data "aws_iam_policy_document" "flow_logs" {
  count = var.flow_logs.enabled ? 1 : 0

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.flow_logs.enabled ? 1 : 0

  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.flow_logs.enabled ? 1 : 0

  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn    = aws_iam_role.flow_logs[0].arn
  tags            = merge(local.tags, { Name = var.name })
}
