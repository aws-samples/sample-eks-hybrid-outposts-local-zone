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
    defaults = { instance_types = ["m7i.large", "c6id.2xlarge"] }
  }
  mock_data "aws_ec2_instance_type_offerings" {
    defaults = { instance_types = ["t3.xlarge", "c5.2xlarge"] }
  }
  mock_data "aws_eks_addon_version" {
    defaults = { version = "v0.0.0-eksbuild.1" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      endpoint              = "https://ABCDEF.gr7.us-east-1.eks.amazonaws.com"
      certificate_authority = [{ data = "LS0tLS1CRUdJTi0tLS0t" }]
      arn                   = "arn:aws:eks:us-east-1:111122223333:cluster/eks-outposts"
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
  name                         = "eks-outposts"
  kubernetes_version           = "1.37"
  location                     = "outposts"
  outpost_arn                  = "arn:aws:outposts:us-east-1:111122223333:outpost/op-0123456789abcdef0"
  vpc_id                       = "vpc-0aaaaaaaaaaaaaaaa"
  control_plane_subnet_ids     = ["subnet-0a000000000000001", "subnet-0a000000000000002"]
  edge_subnet_id               = "subnet-0a00000000000000e"
  peer_cidrs                   = ["10.1.0.0/16"]
  endpoint_public_access_cidrs = ["203.0.113.10/32"]
  instance_type                = "m7i.large"
  root_volume                  = { type = "gp3" }
  # Applied runs tear down for real; keep the destroy-time aws CLI call out of tests.
  cleanup_cni_enis_on_destroy = false
}

run "nodes_run_on_the_edge_subnet" {
  command = apply

  assert {
    condition     = aws_autoscaling_group.nodes.vpc_zone_identifier == toset([var.edge_subnet_id])
    error_message = "Worker nodes must launch only in the edge subnet."
  }

  assert {
    condition     = toset(aws_eks_cluster.this.vpc_config[0].subnet_ids) == toset(var.control_plane_subnet_ids)
    error_message = "The control plane must use the regional subnets."
  }
}

run "addons_use_latest_compatible_version" {
  command = apply

  override_data {
    target = data.aws_eks_addon_version.this["vpc-cni"]
    values = { version = "v1.20.0-eksbuild.1" }
  }
  override_data {
    target = data.aws_eks_addon_version.this["kube-proxy"]
    values = { version = "v1.37.0-eksbuild.2" }
  }
  override_data {
    target = data.aws_eks_addon_version.this["coredns"]
    values = { version = "v1.13.1-eksbuild.3" }
  }

  assert {
    condition = alltrue([
      for k, d in data.aws_eks_addon_version.this : d.most_recent && d.kubernetes_version == var.kubernetes_version
    ])
    error_message = "Add-on versions must be the most recent release for the cluster's Kubernetes version."
  }

  assert {
    condition = (
      aws_eks_addon.vpc_cni.addon_version == "v1.20.0-eksbuild.1" &&
      aws_eks_addon.kube_proxy.addon_version == "v1.37.0-eksbuild.2" &&
      aws_eks_addon.coredns.addon_version == "v1.13.1-eksbuild.3"
    )
    error_message = "Each add-on must install the version resolved for it."
  }
}

run "cni_eni_cleanup_runs_before_the_node_security_group_is_deleted" {
  # Plan only: an applied run would execute the destroy-time aws CLI call at teardown.
  command = plan

  variables {
    cleanup_cni_enis_on_destroy = true
  }

  assert {
    condition = (
      length(terraform_data.cni_eni_cleanup) == 1 &&
      terraform_data.cni_eni_cleanup[0].input.cluster_name == var.name &&
      terraform_data.cni_eni_cleanup[0].input.vpc_id == var.vpc_id &&
      terraform_data.cni_eni_cleanup[0].input.region == "us-east-1" &&
      endswith(terraform_data.cni_eni_cleanup[0].input.script, "scripts/cleanup-cni-enis.sh")
    )
    error_message = "The ENI cleanup must target this cluster's VPC and region with the bundled script."
  }
}

run "cni_eni_cleanup_can_be_disabled" {
  command = plan

  assert {
    condition     = length(terraform_data.cni_eni_cleanup) == 0
    error_message = "cleanup_cni_enis_on_destroy = false must not create the cleanup resource."
  }
}

run "launch_template_is_hardened" {
  command = apply

  assert {
    condition     = aws_launch_template.nodes.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }

  assert {
    condition     = aws_launch_template.nodes.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDS hop limit should default to 1."
  }

  assert {
    condition     = aws_launch_template.nodes.block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "Root volumes must be encrypted."
  }

  assert {
    condition     = aws_launch_template.nodes.block_device_mappings[0].ebs[0].volume_type == "gp3"
    error_message = "Root volume type must follow var.root_volume."
  }

  assert {
    condition     = aws_launch_template.nodes.image_id == "ami-0123456789abcdef0"
    error_message = "Nodes must use the EKS-optimized AMI from SSM."
  }
}

run "nodes_join_with_gateway_labels" {
  command = apply

  assert {
    condition     = strcontains(base64decode(aws_launch_template.nodes.user_data), "edge-mesh.io/gateway=true")
    error_message = "Nodes must carry the gateway label used for meshNetworks discovery."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.nodes.user_data), "cidr: 172.20.0.0/16")
    error_message = "nodeadm must receive the cluster service CIDR."
  }

  assert {
    condition     = aws_eks_access_entry.node.type == "EC2_LINUX"
    error_message = "The node role needs an EC2_LINUX access entry."
  }
}

run "control_plane_is_encrypted_and_logged" {
  command = apply

  assert {
    condition     = aws_eks_cluster.this.encryption_config[0].resources == toset(["secrets"])
    error_message = "Kubernetes secrets must be envelope-encrypted with KMS."
  }

  assert {
    condition     = length(aws_eks_cluster.this.enabled_cluster_log_types) == 5
    error_message = "All control plane log types should be enabled by default."
  }

  assert {
    condition     = aws_kms_key.this.enable_key_rotation
    error_message = "KMS key rotation must be enabled."
  }

  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API"
    error_message = "Use EKS access entries (API authentication mode)."
  }
}

run "kms_key_policy_uses_explicit_least_privilege_actions" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for s in data.aws_iam_policy_document.kms.statement : [for a in s.actions : !strcontains(a, "*")]
    ]))
    error_message = "KMS key policy actions must be explicit, with no wildcards."
  }

  assert {
    condition = length(setintersection(
      toset([for s in data.aws_iam_policy_document.kms.statement : s.actions if s.sid == "AccountAdministration"][0]),
      toset(["kms:Encrypt", "kms:Decrypt", "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext"])
    )) == 0
    error_message = "The account administration statement must not grant data-plane (encrypt/decrypt) actions."
  }

  assert {
    condition     = contains([for s in data.aws_iam_policy_document.kms.statement : s.actions if s.sid == "AccountAdministration"][0], "kms:PutKeyPolicy")
    error_message = "The account must keep kms:PutKeyPolicy so the key cannot be locked out."
  }
}

run "kms_admins_default_to_the_terraform_role" {
  command = plan

  assert {
    condition = flatten([
      for s in data.aws_iam_policy_document.kms.statement : [for p in s.principals : p.identifiers] if s.sid == "AccountAdministration"
    ]) == ["arn:aws:iam::111122223333:root"]
    error_message = "The administration statement's principal should stay the account root, narrowed by condition."
  }

  assert {
    condition = flatten([
      for s in data.aws_iam_policy_document.kms.statement : [
        for c in s.condition : c.values if c.test == "ArnLike" && c.variable == "aws:PrincipalArn"
      ] if s.sid == "AccountAdministration"
    ]) == ["arn:aws:iam::111122223333:role/Deployer"]
    error_message = "With no kms_admin_principal_arns, only the role running Terraform should administer the key."
  }
}

run "kms_admins_can_be_named_roles" {
  command = plan

  variables {
    kms_admin_principal_arns = ["arn:aws:iam::111122223333:role/Deployer", "arn:aws:iam::111122223333:role/BreakGlass"]
  }

  assert {
    condition = toset(flatten([
      for s in data.aws_iam_policy_document.kms.statement : [
        for c in s.condition : c.values if c.test == "ArnLike" && c.variable == "aws:PrincipalArn"
      ] if s.sid == "AccountAdministration"
    ])) == toset(["arn:aws:iam::111122223333:role/Deployer", "arn:aws:iam::111122223333:role/BreakGlass"])
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

run "only_peer_networks_reach_the_eastwest_gateway" {
  command = apply

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.eastwest_from_peers) == 1
    error_message = "Expected one 15443 rule per peer CIDR."
  }

  assert {
    condition = alltrue([
      for r in aws_vpc_security_group_ingress_rule.eastwest_from_peers :
      r.from_port == 15443 && r.to_port == 15443 && r.ip_protocol == "tcp" && r.cidr_ipv4 == "10.1.0.0/16"
    ])
    error_message = "The east-west rule must allow only TCP 15443 from the peer CIDR."
  }
}

run "local_zone_cluster" {
  command = apply

  variables {
    name            = "eks-localzone"
    location        = "localzone"
    outpost_arn     = null
    local_zone_name = "us-east-1-mia-2"
    instance_type   = "t3.xlarge"
    root_volume     = { type = "gp2" }
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.nodes.user_data), "edge-mesh.io/location=localzone")
    error_message = "Local Zone nodes must be labelled with their location."
  }
}

run "rejects_instance_type_not_on_the_outposts" {
  command = plan

  variables {
    instance_type = "r7i.48xlarge"
  }

  expect_failures = [aws_launch_template.nodes]
}

run "rejects_world_open_endpoint" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "rejects_bad_node_group_sizes" {
  command = plan

  variables {
    node_group = { min_size = 3, desired_size = 1, max_size = 2 }
  }

  expect_failures = [var.node_group]
}

run "world_open_endpoint_needs_explicit_opt_in" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["0.0.0.0/0"]
    allow_public_access_anywhere = true
  }

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].public_access_cidrs == toset(["0.0.0.0/0"])
    error_message = "With the lab opt-in, the public endpoint may be opened to 0.0.0.0/0."
  }

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_private_access
    error_message = "The private endpoint must stay on even when the public one is open."
  }
}

run "kms_key_has_maximum_deletion_window" {
  command = plan

  assert {
    condition     = aws_kms_key.this.deletion_window_in_days == 30
    error_message = "The cluster key must wait 30 days before deletion so an accidental or malicious deletion can be cancelled."
  }
}

run "rejects_kms_deletion_window_out_of_range" {
  command = plan

  variables {
    kms_deletion_window_days = 31
  }

  expect_failures = [var.kms_deletion_window_days]
}

run "cluster_creator_is_admin_by_default_with_no_extra_admins" {
  command = plan

  assert {
    condition     = aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions
    error_message = "The default must keep the cluster-creator admin entry (changing it replaces existing clusters)."
  }

  assert {
    condition     = length(aws_eks_access_entry.admin) == 0 && length(aws_eks_access_policy_association.admin) == 0
    error_message = "No named admin entries should exist unless cluster_admin_principal_arns is set."
  }
}

run "named_admins_replace_the_cluster_creator" {
  command = plan

  variables {
    bootstrap_cluster_creator_admin_permissions = false
    cluster_admin_principal_arns = [
      "arn:aws:iam::111122223333:role/Deployer",
      "arn:aws:iam::111122223333:role/BreakGlass",
    ]
  }

  assert {
    condition     = !aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions
    error_message = "bootstrap_cluster_creator_admin_permissions = false must reach the cluster."
  }

  assert {
    condition     = toset(keys(aws_eks_access_entry.admin)) == toset(["arn:aws:iam::111122223333:role/Deployer", "arn:aws:iam::111122223333:role/BreakGlass"])
    error_message = "Each named admin needs an access entry."
  }

  assert {
    condition = alltrue([for a in aws_eks_access_policy_association.admin :
      endswith(a.policy_arn, ":cluster-access-policy/AmazonEKSClusterAdminPolicy") && a.access_scope[0].type == "cluster"
    ])
    error_message = "Named admins get AmazonEKSClusterAdminPolicy at cluster scope."
  }
}

run "rejects_no_admin_at_all" {
  command = plan

  variables {
    bootstrap_cluster_creator_admin_permissions = false
  }

  expect_failures = [var.cluster_admin_principal_arns]
}

run "rejects_wildcard_admin_arn" {
  command = plan

  variables {
    cluster_admin_principal_arns = ["arn:aws:iam::111122223333:role/AWSReservedSSO_Admin_*"]
  }

  expect_failures = [var.cluster_admin_principal_arns]
}

run "rejects_near_world_endpoint_cidr" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["0.0.0.0/1", "128.0.0.0/1"]
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "reader_token_alarm_is_off_by_default" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.reader_token_unexpected_source) == 0 && length(aws_cloudwatch_log_metric_filter.reader_token_unexpected_source) == 0
    error_message = "The reader token alarm must only exist when reader_token_alarm is set."
  }
}

run "reader_token_alarm_flags_use_from_other_ips" {
  command = plan

  variables {
    reader_token_alarm = {
      allowed_source_ips = ["198.51.100.7"]
      alarm_actions      = ["arn:aws:sns:us-east-1:111122223333:security-alerts"]
    }
  }

  assert {
    condition     = aws_cloudwatch_log_metric_filter.reader_token_unexpected_source[0].log_group_name == "/aws/eks/eks-outposts/cluster"
    error_message = "The filter must read the cluster's control plane (audit) log group."
  }

  assert {
    condition     = aws_cloudwatch_log_metric_filter.reader_token_unexpected_source[0].pattern == "{ ($.user.username = \"system:serviceaccount:istio-system:istio-reader-service-account\") && ($.sourceIPs[0] != \"198.51.100.7\") }"
    error_message = "The filter must match reader token use from any IP except the allowed peer NAT IP."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.reader_token_unexpected_source[0].threshold == 1 && aws_cloudwatch_metric_alarm.reader_token_unexpected_source[0].treat_missing_data == "notBreaching"
    error_message = "A single unexpected use must raise the alarm, and silence must not."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.reader_token_unexpected_source[0].alarm_actions == toset(["arn:aws:sns:us-east-1:111122223333:security-alerts"])
    error_message = "The alarm must notify the configured actions."
  }
}

run "reader_token_alarm_allows_every_peer_nat_ip" {
  command = plan

  variables {
    reader_token_alarm = { allowed_source_ips = ["198.51.100.7", "198.51.100.8"] }
  }

  assert {
    condition     = strcontains(aws_cloudwatch_log_metric_filter.reader_token_unexpected_source[0].pattern, "($.sourceIPs[0] != \"198.51.100.7\") && ($.sourceIPs[0] != \"198.51.100.8\")")
    error_message = "Every allowed IP must be excluded from the filter."
  }
}

run "reader_token_alarm_rejects_cidrs" {
  command = plan

  variables {
    reader_token_alarm = { allowed_source_ips = ["198.51.100.0/24"] }
  }

  expect_failures = [var.reader_token_alarm]
}

run "reader_token_alarm_needs_audit_logs" {
  command = plan

  variables {
    cluster_log_types  = ["api"]
    reader_token_alarm = { allowed_source_ips = ["198.51.100.7"] }
  }

  expect_failures = [var.reader_token_alarm]
}
