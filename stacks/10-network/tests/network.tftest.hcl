# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Wiring tests for the network stack with a mocked AWS provider.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333", arn = "arn:aws:sts::111122223333:assumed-role/Deployer/session" }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::111122223333:role/Deployer" }
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
  mock_data "aws_outposts_outpost" {
    defaults = { availability_zone = "us-east-1a" }
  }
  mock_data "aws_availability_zone" {
    defaults = { parent_zone_name = "us-east-1d", group_name = "us-east-1-mia-2" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"] }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:111122223333:log-group:mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
}

variables {
  region          = "us-east-1"
  outpost_arn     = "arn:aws:outposts:us-east-1:111122223333:outpost/op-0123456789abcdef0"
  local_zone_name = "us-east-1-mia-2"
}

run "regional_subnets_follow_the_edge_locations" {
  command = apply

  assert {
    condition     = output.network.outposts.availability_zone == "us-east-1a"
    error_message = "The Outposts VPC must anchor on the Outposts Availability Zone."
  }

  assert {
    condition     = output.network.localzone.parent_zone == "us-east-1d"
    error_message = "The Local Zone VPC must anchor on the Local Zone's parent Availability Zone."
  }

  assert {
    condition     = local.outposts_second_az != local.outposts_az && local.localzone_second_az != local.local_zone_parent
    error_message = "Each VPC needs a second, different regional AZ for the EKS control plane."
  }
}

run "local_zone_group_is_opted_in" {
  command = apply

  assert {
    condition     = aws_ec2_availability_zone_group.local_zone[0].opt_in_status == "opted-in" && aws_ec2_availability_zone_group.local_zone[0].group_name == "us-east-1-mia-2"
    error_message = "The Local Zone group must be opted in before its subnet is created."
  }
}

run "vpcs_are_peered_with_all_routes" {
  command = apply

  assert {
    condition     = module.peering.route_count == 4
    error_message = "Peering must add routes to all four route tables."
  }

  assert {
    condition     = output.network.outposts.vpc_cidr == "10.3.0.0/16" && output.network.localzone.vpc_cidr == "10.2.0.0/16"
    error_message = "Default address plan changed unexpectedly."
  }
}

run "flow_logs_use_a_rotating_kms_key" {
  command = apply

  assert {
    condition     = aws_kms_key.logs[0].enable_key_rotation
    error_message = "The flow logs KMS key must rotate."
  }

  assert {
    condition = alltrue(flatten([
      for s in data.aws_iam_policy_document.logs_kms.statement : [for a in s.actions : !strcontains(a, "*")]
    ]))
    error_message = "KMS key policy actions must be explicit, with no wildcards."
  }

  assert {
    condition = length(setintersection(
      toset([for s in data.aws_iam_policy_document.logs_kms.statement : s.actions if s.sid == "AccountAdministration"][0]),
      toset(["kms:Encrypt", "kms:Decrypt", "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext"])
    )) == 0
    error_message = "The account administration statement must not grant data-plane (encrypt/decrypt) actions."
  }

  assert {
    condition     = contains([for s in data.aws_iam_policy_document.logs_kms.statement : s.actions if s.sid == "AccountAdministration"][0], "kms:PutKeyPolicy")
    error_message = "The account must keep kms:PutKeyPolicy so the key cannot be locked out."
  }
}

run "flow_logs_kms_admins_default_to_the_terraform_role" {
  command = plan

  assert {
    condition = flatten([
      for s in data.aws_iam_policy_document.logs_kms.statement : [for p in s.principals : p.identifiers] if s.sid == "AccountAdministration"
    ]) == ["arn:aws:iam::111122223333:root"]
    error_message = "The administration statement's principal should stay the account root, narrowed by condition."
  }

  assert {
    condition = flatten([
      for s in data.aws_iam_policy_document.logs_kms.statement : [
        for c in s.condition : c.values if c.test == "ArnLike" && c.variable == "aws:PrincipalArn"
      ] if s.sid == "AccountAdministration"
    ]) == ["arn:aws:iam::111122223333:role/Deployer"]
    error_message = "With no kms_admin_principal_arns, only the role running Terraform should administer the key."
  }
}

run "flow_logs_kms_admins_can_be_named_roles" {
  command = plan

  variables {
    kms_admin_principal_arns = ["arn:aws:iam::111122223333:role/BreakGlass"]
  }

  assert {
    condition = flatten([
      for s in data.aws_iam_policy_document.logs_kms.statement : [
        for c in s.condition : c.values if c.test == "ArnLike" && c.variable == "aws:PrincipalArn"
      ] if s.sid == "AccountAdministration"
    ]) == ["arn:aws:iam::111122223333:role/BreakGlass"]
    error_message = "kms_admin_principal_arns should name the key administrators."
  }
}

run "rejects_non_iam_kms_admin" {
  command = plan

  variables {
    kms_admin_principal_arns = ["arn:aws:s3:::not-a-principal"]
  }

  expect_failures = [var.kms_admin_principal_arns]
}

run "rejects_malformed_outpost_arn" {
  command = plan

  variables {
    outpost_arn = "op-0123456789abcdef0"
  }

  expect_failures = [var.outpost_arn]
}

run "flow_logs_kms_key_has_maximum_deletion_window" {
  command = plan

  assert {
    condition     = aws_kms_key.logs[0].deletion_window_in_days == 30
    error_message = "The flow logs key must wait 30 days before deletion so an accidental or malicious deletion can be cancelled."
  }
}

run "rejects_kms_deletion_window_out_of_range" {
  command = plan

  variables {
    kms_deletion_window_days = 5
  }

  expect_failures = [var.kms_deletion_window_days]
}
