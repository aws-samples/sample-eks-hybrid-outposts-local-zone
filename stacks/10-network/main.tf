# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

provider "aws" {
  region = var.region

  default_tags {
    tags = merge(var.tags, {
      Project   = "eks-hybrid-edge-mesh"
      ManagedBy = "terraform"
      Stack     = "10-network"
    })
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

# ---------------------------------------------------------------------------
# Discovery: Outposts AZ, Local Zone parent AZ, and a second regional AZ for each VPC
# ---------------------------------------------------------------------------

data "aws_outposts_outpost" "this" {
  arn = var.outpost_arn
}

data "aws_availability_zone" "local_zone" {
  name                   = var.local_zone_name
  all_availability_zones = true
}

data "aws_availability_zones" "regional" {
  #checkov:skip=CKV_AWS_394:Only used to pick the second control plane AZ: the first name (sorted) that differs from the anchor AZ. New AZs sort after existing ones, so the choice is stable.
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  outposts_az       = data.aws_outposts_outpost.this.availability_zone
  local_zone_parent = data.aws_availability_zone.local_zone.parent_zone_name

  outposts_second_az   = [for az in data.aws_availability_zones.regional.names : az if az != local.outposts_az][0]
  localzone_second_az  = [for az in data.aws_availability_zones.regional.names : az if az != local.local_zone_parent][0]
  flow_log_kms_key_arn = var.enable_flow_logs ? aws_kms_key.logs[0].arn : null

  # Who may administer the flow logs KMS key. Default: the IAM role (or user) running
  # Terraform, resolved from an assumed-role session to the role ARN.
  kms_admin_principals = length(var.kms_admin_principal_arns) > 0 ? var.kms_admin_principal_arns : [
    data.aws_iam_session_context.current.issuer_arn,
  ]

  # Explicit KMS actions (no wildcards); keep in step with modules/eks-edge-cluster.
  # The admin list keeps PutKeyPolicy so the key stays recoverable through IAM; it has
  # no Encrypt/Decrypt.
  kms_admin_actions = [
    "kms:CancelKeyDeletion",
    "kms:CreateAlias",
    "kms:CreateGrant",
    "kms:DeleteAlias",
    "kms:DescribeKey",
    "kms:DisableKey",
    "kms:DisableKeyRotation",
    "kms:EnableKey",
    "kms:EnableKeyRotation",
    "kms:GetKeyPolicy",
    "kms:GetKeyRotationStatus",
    "kms:ListGrants",
    "kms:ListKeyPolicies",
    "kms:ListResourceTags",
    "kms:PutKeyPolicy",
    "kms:RetireGrant",
    "kms:RevokeGrant",
    "kms:ScheduleKeyDeletion",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:UpdateAlias",
    "kms:UpdateKeyDescription",
  ]

  kms_logs_actions = [
    "kms:Decrypt",
    "kms:DescribeKey",
    "kms:Encrypt",
    "kms:GenerateDataKey",
    "kms:GenerateDataKeyWithoutPlaintext",
    "kms:ReEncryptFrom",
    "kms:ReEncryptTo",
  ]
}

resource "aws_ec2_availability_zone_group" "local_zone" {
  count = var.manage_local_zone_opt_in ? 1 : 0

  group_name    = data.aws_availability_zone.local_zone.group_name
  opt_in_status = "opted-in"
}

# ---------------------------------------------------------------------------
# KMS key for VPC Flow Logs
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "logs_kms" {
  #checkov:skip=CKV_AWS_356:A key policy's resource is always the key itself ("*").
  statement {
    # Key management only, for the named administrators; data-plane use is limited to
    # CloudWatch Logs below. Same pattern as modules/eks-edge-cluster: root principal
    # narrowed by aws:PrincipalArn, so recreating a deleted admin role by name restores
    # access. Every role that runs plan, apply, or destroy must be in the list.
    sid       = "AccountAdministration"
    actions   = local.kms_admin_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = local.kms_admin_principals
    }
  }

  statement {
    sid       = "CloudWatchLogsFlowLogs"
    actions   = local.kms_logs_actions
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/vpc/${var.name_prefix}-*"]
    }
  }
}

resource "aws_kms_key" "logs" {
  count = var.enable_flow_logs ? 1 : 0

  description             = "VPC Flow Logs encryption for ${var.name_prefix}"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_deletion_window_days
  policy                  = data.aws_iam_policy_document.logs_kms.json
}

resource "aws_kms_alias" "logs" {
  count = var.enable_flow_logs ? 1 : 0

  name          = "alias/${var.name_prefix}/flow-logs"
  target_key_id = aws_kms_key.logs[0].key_id
}

# ---------------------------------------------------------------------------
# VPCs and peering
# ---------------------------------------------------------------------------

# Renamed from vpc_outpost; keeps existing VPCs instead of replacing them.
moved {
  from = module.vpc_outpost
  to   = module.vpc_outposts
}

module "vpc_outposts" {
  source = "../../modules/edge-vpc"

  name       = "${var.name_prefix}-outposts"
  cidr_block = var.cidrs.outposts.vpc
  regional_subnets = [
    { cidr = var.cidrs.outposts.regional[0], availability_zone = local.outposts_az },
    { cidr = var.cidrs.outposts.regional[1], availability_zone = local.outposts_second_az },
  ]
  edge_type              = "outposts"
  edge_subnet_cidr       = var.cidrs.outposts.edge
  edge_availability_zone = local.outposts_az
  outpost_arn            = var.outpost_arn

  flow_logs = {
    enabled     = var.enable_flow_logs
    kms_key_arn = local.flow_log_kms_key_arn
  }
}

module "vpc_localzone" {
  source = "../../modules/edge-vpc"

  name       = "${var.name_prefix}-localzone"
  cidr_block = var.cidrs.localzone.vpc
  regional_subnets = [
    { cidr = var.cidrs.localzone.regional[0], availability_zone = local.local_zone_parent },
    { cidr = var.cidrs.localzone.regional[1], availability_zone = local.localzone_second_az },
  ]
  edge_type              = "localzone"
  edge_subnet_cidr       = var.cidrs.localzone.edge
  edge_availability_zone = var.local_zone_name

  flow_logs = {
    enabled     = var.enable_flow_logs
    kms_key_arn = local.flow_log_kms_key_arn
  }

  depends_on = [aws_ec2_availability_zone_group.local_zone]
}

module "peering" {
  source = "../../modules/vpc-peering"

  name = "${var.name_prefix}-outposts-to-localzone"

  requester = {
    vpc_id          = module.vpc_outposts.vpc_id
    cidr            = module.vpc_outposts.vpc_cidr
    route_table_ids = module.vpc_outposts.route_table_ids
  }

  accepter = {
    vpc_id          = module.vpc_localzone.vpc_id
    cidr            = module.vpc_localzone.vpc_cidr
    route_table_ids = module.vpc_localzone.route_table_ids
  }
}
