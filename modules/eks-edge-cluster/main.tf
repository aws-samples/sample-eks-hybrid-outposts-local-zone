# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  tags       = merge(var.tags, { "edge-mesh:cluster" = var.name })
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # Every node in this group runs the east-west gateway (DaemonSet, hostPort 15443),
  # so the label below is what the mesh stack uses to discover gateway IPs.
  node_labels = merge(var.node_labels, {
    "edge-mesh.io/location" = var.location
    "edge-mesh.io/gateway"  = "true"
  })

  # Who may administer the KMS key. Default: the IAM role (or user) running Terraform,
  # resolved from an assumed-role session to the role ARN.
  kms_admin_principals = length(var.kms_admin_principal_arns) > 0 ? var.kms_admin_principal_arns : [
    data.aws_iam_session_context.current.issuer_arn,
  ]

  # Explicit KMS actions (no wildcards). The admin list keeps PutKeyPolicy so the key
  # stays recoverable through IAM; it has no Encrypt/Decrypt.
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

  # What CloudWatch Logs needs on a symmetric key (the explicit form of AWS's documented
  # Encrypt*/Decrypt*/ReEncrypt*/GenerateDataKey*/Describe* example).
  kms_logs_actions = [
    "kms:Decrypt",
    "kms:DescribeKey",
    "kms:Encrypt",
    "kms:GenerateDataKey",
    "kms:GenerateDataKeyWithoutPlaintext",
    "kms:ReEncryptFrom",
    "kms:ReEncryptTo",
  ]

  available_instance_types = var.location == "outposts" ? (
    data.aws_outposts_outpost_instance_types.this[0].instance_types
    ) : (
    data.aws_ec2_instance_type_offerings.this[0].instance_types
  )
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

data "aws_ssm_parameter" "ami" {
  name = "/aws/service/eks/optimized-ami/${var.kubernetes_version}/amazon-linux-2023/${var.ami_architecture}/standard/recommended/image_id"
}

# Latest add-on version compatible with the cluster's Kubernetes version. Resolved on every
# plan, so a newer EKS release of an add-on shows up as an in-place update.
data "aws_eks_addon_version" "this" {
  for_each           = toset(["vpc-cni", "kube-proxy", "coredns"])
  addon_name         = each.key
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

data "aws_outposts_outpost_instance_types" "this" {
  count = var.location == "outposts" ? 1 : 0
  arn   = var.outpost_arn
}

data "aws_ec2_instance_type_offerings" "this" {
  count         = var.location == "localzone" ? 1 : 0
  location_type = "availability-zone"

  filter {
    name   = "location"
    values = [var.local_zone_name]
  }
}

# ---------------------------------------------------------------------------
# Encryption and logging
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "kms" {
  #checkov:skip=CKV_AWS_356:A key policy's resource is always the key itself ("*").
  statement {
    # Key management only, for the named administrators. Data-plane use goes through
    # the EKS grant (created with CreateGrant) and the CloudWatch Logs statement below.
    #
    # The principal is the account root, narrowed by aws:PrincipalArn. That condition
    # compares ARN strings, so if an admin role is deleted, recreating a role with the
    # same name restores access (a principal element would bind to the deleted role's
    # unique ID instead). Principals outside the list can't read or change the key,
    # `terraform plan` and `terraform destroy` included: add any other role that runs
    # Terraform to kms_admin_principal_arns.
    sid       = "AccountAdministration"
    actions   = local.kms_admin_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = local.kms_admin_principals
    }
  }

  statement {
    sid       = "CloudWatchLogsControlPlane"
    actions   = local.kms_logs_actions
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/eks/${var.name}/cluster"]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "EKS secrets and control plane log encryption for ${var.name}"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_deletion_window_days
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = local.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/eks/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn
  tags              = local.tags
}

# ---------------------------------------------------------------------------
# Remote-secret token misuse alarm
#
# The peer istiod reads this cluster's API with the istio-reader token, which
# can list every Secret in the cluster. Legitimate use always arrives from the
# peer VPC's NAT IP, so any audit event for that service account from another
# source IP means the token is being used by someone else.
# ---------------------------------------------------------------------------

locals {
  reader_token_alarm_enabled = var.reader_token_alarm != null

  reader_token_filter_pattern = local.reader_token_alarm_enabled ? format(
    "{ ($.user.username = \"%s\") && %s }",
    var.reader_token_alarm.username,
    join(" && ", [for ip in var.reader_token_alarm.allowed_source_ips : "($.sourceIPs[0] != \"${ip}\")"]),
  ) : null
}

resource "aws_cloudwatch_log_metric_filter" "reader_token_unexpected_source" {
  count = local.reader_token_alarm_enabled ? 1 : 0

  name           = "${var.name}-istio-reader-unexpected-source"
  log_group_name = aws_cloudwatch_log_group.cluster.name
  pattern        = local.reader_token_filter_pattern

  metric_transformation {
    name      = "IstioReaderTokenUnexpectedSource"
    namespace = "EdgeMesh/${var.name}"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "reader_token_unexpected_source" {
  count = local.reader_token_alarm_enabled ? 1 : 0

  alarm_name          = "${var.name}-istio-reader-token-misuse"
  alarm_description   = "The istio-reader token of ${var.name} was used from an IP other than the peer NAT. Rotate it (apply the mesh stack after lowering remote_secret_token_rotation_days, or delete the istio-reader-token-* Secret) and investigate."
  namespace           = "EdgeMesh/${var.name}"
  metric_name         = "IstioReaderTokenUnexpectedSource"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.reader_token_alarm.alarm_actions
  tags                = local.tags

  depends_on = [aws_cloudwatch_log_metric_filter.reader_token_unexpected_source]
}

# ---------------------------------------------------------------------------
# Control plane
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name_prefix        = "${substr(var.name, 0, 24)}-cluster-"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" { # nosemgrep: terraform.lang.security.eks-public-endpoint-enabled.eks-public-endpoint-enabled -- required for cross-VPC istiod; CIDR-restricted (see CKV_AWS_39 skip)
  #checkov:skip=CKV_AWS_39:The public endpoint is required so the peer VPC's istiod can watch this API (EKS private endpoint DNS is not resolvable across VPC peering). It is restricted to admin and peer NAT CIDRs; 0.0.0.0/0 is rejected by variable validation unless the lab-only allow_public_access_anywhere opt-in is set.
  #checkov:skip=CKV_AWS_339:Checkov's static version list lags EKS releases; the default version is checked against "aws eks describe-cluster-versions".
  name                      = var.name # nosemgrep: terraform.lang.security.eks-insufficient-control-plane-logging.eks-insufficient-control-plane-logging -- var.cluster_log_types defaults to all five types incl. api and audit
  version                   = var.kubernetes_version
  role_arn                  = aws_iam_role.cluster.arn
  enabled_cluster_log_types = var.cluster_log_types

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin_permissions
  }

  vpc_config {
    subnet_ids              = var.control_plane_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.endpoint_public_access_cidrs : null
  }

  kubernetes_network_config {
    ip_family         = "ipv4"
    service_ipv4_cidr = var.service_ipv4_cidr
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = aws_kms_key.this.arn
    }
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.this["vpc-cni"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = data.aws_eks_addon_version.this["kube-proxy"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.tags
}

# CoreDNS needs nodes to become ACTIVE, so it is created after the Auto Scaling group.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.this["coredns"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.tags

  depends_on = [aws_autoscaling_group.nodes]
}

# ---------------------------------------------------------------------------
# Node security group
#
# Nodes are members of both this security group and the EKS cluster security
# group. Cluster security group membership covers control plane <-> node
# traffic, including the Istio sidecar-injection webhook (TCP 15017) and
# istiod (TCP 15012). This group only adds what crosses the mesh networks.
# ---------------------------------------------------------------------------

resource "aws_security_group" "nodes" {
  name_prefix = "${substr(var.name, 0, 24)}-nodes-"
  description = "Edge mesh traffic for ${var.name} worker nodes"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "${var.name}-nodes" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "nodes_self" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  description                  = "Node to node and Pod to Pod"
}

resource "aws_vpc_security_group_ingress_rule" "eastwest_from_peers" {
  for_each = toset(var.peer_cidrs)

  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 15443
  to_port           = 15443
  description       = "Istio east-west gateway (mTLS AUTO_PASSTHROUGH) from peer mesh network"
}

resource "aws_vpc_security_group_ingress_rule" "icmp_from_peers" {
  for_each = toset(var.peer_cidrs)

  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = each.value
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  description       = "ICMP from peer mesh network (path MTU discovery, troubleshooting)"
}

# The VPC CNI can leave its secondary ENIs "available" after the nodes terminate
# (seen on Outposts subnets). They carry both the node security group and the
# EKS-managed cluster security group. Left in place, deleting the node security
# group fails with DependencyViolation, and EKS silently leaves its cluster
# security group behind, which then blocks deleting the VPC.
#
# Destroy order: Auto Scaling group, then this cleanup, then the node security
# group and the EKS cluster. The ASG depends on this resource; this resource
# depends on the security group and on the cluster (through cluster_name).
resource "terraform_data" "cni_eni_cleanup" {
  count = var.cleanup_cni_enis_on_destroy ? 1 : 0

  input = {
    script = abspath("${path.module}/scripts/cleanup-cni-enis.sh")
    region = local.region
    # From the cluster resource, not var.name, so the cluster is deleted after the cleanup.
    cluster_name      = aws_eks_cluster.this.name
    vpc_id            = var.vpc_id
    security_group_id = aws_security_group.nodes.id
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash \"${self.input.script}\" \"${self.input.region}\" \"${self.input.cluster_name}\" \"${self.input.vpc_id}\" \"${self.input.security_group_id}\""
  }
}

resource "aws_vpc_security_group_egress_rule" "nodes_all" {
  #checkov:skip=CKV_AWS_382:Worker nodes need egress to the EKS API, ECR, AWS APIs, and the peer mesh network.
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All egress"
}

# ---------------------------------------------------------------------------
# Self-managed nodes (EKS managed node groups are not supported on Outposts)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name_prefix        = "${substr(var.name, 0, 24)}-node-"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

resource "aws_iam_instance_profile" "node" {
  name_prefix = "${substr(var.name, 0, 24)}-node-"
  role        = aws_iam_role.node.name
  tags        = local.tags
}

resource "aws_eks_access_entry" "node" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"
  tags          = local.tags
}

# Named cluster administrators. Lets you separate the deployment role from the people or
# break-glass roles that administer the cluster, and turn off the implicit cluster-creator admin.
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
  tags          = local.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admin[each.value].principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_launch_template" "nodes" {
  name_prefix            = "${var.name}-"
  image_id               = nonsensitive(data.aws_ssm_parameter.ami.value)
  instance_type          = var.instance_type
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.node.arn
  }

  vpc_security_group_ids = [
    aws_security_group.nodes.id,
    aws_eks_cluster.this.vpc_config[0].cluster_security_group_id,
  ]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = var.imds_hop_limit
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume.size_gib
      volume_type           = var.root_volume.type
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/nodeadm-userdata.tftpl", {
    cluster_name        = aws_eks_cluster.this.name
    api_server_endpoint = aws_eks_cluster.this.endpoint
    certificate_data    = aws_eks_cluster.this.certificate_authority[0].data
    service_cidr        = var.service_ipv4_cidr
    node_labels         = join(",", [for k, v in local.node_labels : "${k}=${v}"])
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.tags, {
      Name                                = "${var.name}-node"
      "kubernetes.io/cluster/${var.name}" = "owned"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = "${var.name}-node" })
  }

  tags = local.tags

  lifecycle {
    precondition {
      condition     = contains(local.available_instance_types, var.instance_type)
      error_message = "Instance type ${var.instance_type} is not available on this ${var.location}. Available: ${join(", ", sort(local.available_instance_types))}."
    }
  }
}

resource "aws_autoscaling_group" "nodes" {
  name_prefix         = "${var.name}-"
  min_size            = var.node_group.min_size
  max_size            = var.node_group.max_size
  desired_capacity    = var.node_group.desired_size
  vpc_zone_identifier = [var.edge_subnet_id]
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 0
    }
  }

  tag {
    key                 = "kubernetes.io/cluster/${var.name}"
    value               = "owned"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  depends_on = [
    aws_eks_access_entry.node,
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
    # Destroyed before the ENI cleanup runs, so no new CNI ENIs appear meanwhile.
    terraform_data.cni_eni_cleanup,
  ]
}
