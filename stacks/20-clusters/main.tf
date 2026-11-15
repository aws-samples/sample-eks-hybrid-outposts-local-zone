# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

provider "aws" {
  region = var.network.region

  default_tags {
    tags = merge(var.tags, {
      Project   = "eks-hybrid-edge-mesh"
      ManagedBy = "terraform"
      Stack     = "20-clusters"
    })
  }
}

locals {
  # The peer istiod resolves the other cluster's API endpoint to its public
  # address and connects through its own NAT gateway, so both NAT IPs must be
  # allowed on both public endpoints alongside the admin CIDRs.
  # allow_public_api_from_anywhere (lab only, default false) drops the allow list.
  endpoint_public_access_cidrs = var.allow_public_api_from_anywhere ? ["0.0.0.0/0"] : distinct(concat(var.admin_cidrs, [
    "${var.network.outposts.nat_public_ip}/32",
    "${var.network.localzone.nat_public_ip}/32",
  ]))

  # Each cluster's istio-reader token is used only by the peer istiod, which
  # always arrives through the peer VPC's NAT gateway.
  reader_token_alarm = {
    outposts = var.reader_token_alarm.enabled ? {
      allowed_source_ips = [var.network.localzone.nat_public_ip]
      alarm_actions      = var.reader_token_alarm.alarm_actions
    } : null
    localzone = var.reader_token_alarm.enabled ? {
      allowed_source_ips = [var.network.outposts.nat_public_ip]
      alarm_actions      = var.reader_token_alarm.alarm_actions
    } : null
  }
}

check "admin_cidrs_are_narrow" {
  assert {
    condition     = alltrue([for c in var.admin_cidrs : try(tonumber(split("/", c)[1]) >= 24, false)])
    error_message = "Some admin_cidrs are wider than /24. Everything inside them can reach the EKS API; prefer /32 addresses or small office/CI ranges (see docs/security.md, EKS API endpoint access)."
  }
}

check "public_api_open_to_internet" {
  assert {
    condition     = !var.allow_public_api_from_anywhere
    error_message = "allow_public_api_from_anywhere is true: both EKS API endpoints accept connections from any IP (IAM authentication still applies). Lab use only; see docs/security.md, EKS API endpoint access."
  }
}

module "eks_outposts" {
  source = "../../modules/eks-edge-cluster"

  name                         = "${var.name_prefix}-outposts"
  cleanup_cni_enis_on_destroy  = var.cleanup_cni_enis_on_destroy
  kubernetes_version           = var.kubernetes_version
  location                     = "outposts"
  outpost_arn                  = var.network.outposts.outpost_arn
  vpc_id                       = var.network.outposts.vpc_id
  control_plane_subnet_ids     = var.network.outposts.regional_subnet_ids
  edge_subnet_id               = var.network.outposts.edge_subnet_id
  peer_cidrs                   = [var.network.localzone.vpc_cidr]
  endpoint_public_access_cidrs = local.endpoint_public_access_cidrs
  allow_public_access_anywhere = var.allow_public_api_from_anywhere
  kms_admin_principal_arns     = var.kms_admin_principal_arns
  kms_deletion_window_days     = var.kms_deletion_window_days

  bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin_permissions
  cluster_admin_principal_arns                = var.cluster_admin_principal_arns
  reader_token_alarm                          = local.reader_token_alarm.outposts

  instance_type    = var.outposts_nodes.instance_type
  ami_architecture = var.outposts_nodes.ami_architecture
  node_group = {
    min_size     = var.outposts_nodes.min_size
    max_size     = var.outposts_nodes.max_size
    desired_size = var.outposts_nodes.desired_size
  }
  root_volume = {
    type     = var.outposts_nodes.volume_type
    size_gib = var.outposts_nodes.volume_size_gib
  }
}

module "eks_localzone" {
  source = "../../modules/eks-edge-cluster"

  name                         = "${var.name_prefix}-localzone"
  cleanup_cni_enis_on_destroy  = var.cleanup_cni_enis_on_destroy
  kubernetes_version           = var.kubernetes_version
  location                     = "localzone"
  local_zone_name              = var.network.localzone.local_zone_name
  vpc_id                       = var.network.localzone.vpc_id
  control_plane_subnet_ids     = var.network.localzone.regional_subnet_ids
  edge_subnet_id               = var.network.localzone.edge_subnet_id
  peer_cidrs                   = [var.network.outposts.vpc_cidr]
  endpoint_public_access_cidrs = local.endpoint_public_access_cidrs
  allow_public_access_anywhere = var.allow_public_api_from_anywhere
  kms_admin_principal_arns     = var.kms_admin_principal_arns
  kms_deletion_window_days     = var.kms_deletion_window_days

  bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin_permissions
  cluster_admin_principal_arns                = var.cluster_admin_principal_arns
  reader_token_alarm                          = local.reader_token_alarm.localzone

  instance_type    = var.localzone_nodes.instance_type
  ami_architecture = var.localzone_nodes.ami_architecture
  node_group = {
    min_size     = var.localzone_nodes.min_size
    max_size     = var.localzone_nodes.max_size
    desired_size = var.localzone_nodes.desired_size
  }
  root_volume = {
    type     = var.localzone_nodes.volume_type
    size_gib = var.localzone_nodes.volume_size_gib
  }
}
