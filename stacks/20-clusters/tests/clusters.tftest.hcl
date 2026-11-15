# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

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
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_outposts_outpost_instance_types" {
    defaults = { instance_types = ["m7i.large", "m7i.xlarge"] }
  }
  mock_data "aws_ec2_instance_type_offerings" {
    defaults = { instance_types = ["t3.xlarge", "m6i.xlarge"] }
  }
  mock_data "aws_eks_addon_version" {
    defaults = { version = "v0.0.0-eksbuild.1" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:us-east-1:111122223333:cluster/mock"
      endpoint              = "https://ABCDEF.gr7.us-east-1.eks.amazonaws.com"
      certificate_authority = [{ data = "LS0tLS1CRUdJTi0tLS0t" }]
    }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555" }
  }
  mock_resource "aws_launch_template" {
    defaults = { latest_version = 1, id = "lt-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::111122223333:instance-profile/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:111122223333:log-group:mock" }
  }
}

variables {
  # Applied runs tear down for real; keep the destroy-time aws CLI call out of tests.
  cleanup_cni_enis_on_destroy = false
  admin_cidrs                 = ["203.0.113.10/32"]
  # Pin settings a local terraform.tfvars may override, so tests behave the same everywhere.
  allow_public_api_from_anywhere              = false
  bootstrap_cluster_creator_admin_permissions = true
  cluster_admin_principal_arns                = []
  kms_deletion_window_days                    = 30
  network = {
    region = "us-east-1"
    outposts = {
      vpc_id              = "vpc-0aaaaaaaaaaaaaaaa"
      vpc_cidr            = "10.3.0.0/16"
      regional_subnet_ids = ["subnet-0a000000000000001", "subnet-0a000000000000002"]
      edge_subnet_id      = "subnet-0a00000000000000e"
      nat_public_ip       = "198.51.100.1"
      outpost_arn         = "arn:aws:outposts:us-east-1:111122223333:outpost/op-0123456789abcdef0"
      availability_zone   = "us-east-1a"
    }
    localzone = {
      vpc_id              = "vpc-0bbbbbbbbbbbbbbbb"
      vpc_cidr            = "10.2.0.0/16"
      regional_subnet_ids = ["subnet-0b000000000000001", "subnet-0b000000000000002"]
      edge_subnet_id      = "subnet-0b00000000000000e"
      nat_public_ip       = "198.51.100.2"
      local_zone_name     = "us-east-1-mia-2"
      parent_zone         = "us-east-1d"
    }
    peering_connection_id = "pcx-0123456789abcdef0"
  }
}

run "public_endpoints_allow_admins_and_peer_nat_gateways" {
  command = apply

  assert {
    condition = toset(local.endpoint_public_access_cidrs) == toset([
      "203.0.113.10/32", "198.51.100.1/32", "198.51.100.2/32",
    ])
    error_message = "Each public endpoint must admit the admin CIDRs and both NAT IPs (peer istiod traffic)."
  }
}

run "clusters_get_the_expected_names" {
  command = apply

  assert {
    condition     = output.clusters.outposts.name == "eks-outposts" && output.clusters.localzone.name == "eks-localzone"
    error_message = "Cluster names must match the blog post and the validation scripts."
  }
}

run "rejects_world_open_admin_cidr" {
  command = plan

  variables {
    admin_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.admin_cidrs]
}

run "public_api_stays_allow_listed_by_default" {
  command = plan

  assert {
    condition     = !contains(local.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "The default must keep the EKS public endpoints on the allow list."
  }
}

run "public_api_can_be_opened_for_a_lab" {
  command = plan

  variables {
    allow_public_api_from_anywhere = true
    admin_cidrs                    = []
  }

  assert {
    condition     = toset(local.endpoint_public_access_cidrs) == toset(["0.0.0.0/0"])
    error_message = "allow_public_api_from_anywhere must open both endpoints to 0.0.0.0/0 (admin CIDRs are then optional)."
  }

  expect_failures = [check.public_api_open_to_internet]
}

run "admin_cidr_required_without_opt_in" {
  command = plan

  variables {
    admin_cidrs = []
  }

  expect_failures = [var.admin_cidrs]
}

run "rejects_wide_admin_cidr" {
  command = plan

  variables {
    admin_cidrs = ["0.0.0.0/1"]
  }

  expect_failures = [var.admin_cidrs]
}

run "rejects_private_admin_cidr" {
  command = plan

  variables {
    admin_cidrs = ["192.168.1.0/24"]
  }

  expect_failures = [var.admin_cidrs]
}

run "rejects_cgnat_admin_cidr" {
  command = plan

  variables {
    admin_cidrs = ["100.64.10.0/24"]
  }

  expect_failures = [var.admin_cidrs]
}

run "warns_on_admin_cidr_wider_than_24" {
  command = plan

  variables {
    admin_cidrs = ["198.51.96.0/20"]
  }

  expect_failures = [check.admin_cidrs_are_narrow]
}

run "reader_token_alarm_allows_only_the_peer_nat" {
  command = plan

  assert {
    condition     = local.reader_token_alarm.outposts.allowed_source_ips == ["198.51.100.2"]
    error_message = "The Outposts cluster's reader token is used only by the Local Zone istiod, so only the Local Zone NAT IP is expected (not the cluster's own NAT IP)."
  }

  assert {
    condition     = local.reader_token_alarm.localzone.allowed_source_ips == ["198.51.100.1"]
    error_message = "The Local Zone cluster's reader token is used only by the Outposts istiod, so only the Outposts NAT IP is expected."
  }
}

run "reader_token_alarm_can_be_disabled" {
  command = plan

  variables {
    reader_token_alarm = { enabled = false }
  }

  assert {
    condition     = local.reader_token_alarm.outposts == null && local.reader_token_alarm.localzone == null
    error_message = "reader_token_alarm.enabled = false must turn off both alarms."
  }
}
