# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "network" {
  description = "Output of the 10-network stack. Written to network.auto.tfvars.json by scripts/export-outputs.sh."
  type = object({
    region = string
    outposts = object({
      vpc_id              = string
      vpc_cidr            = string
      regional_subnet_ids = list(string)
      edge_subnet_id      = string
      nat_public_ip       = string
      outpost_arn         = string
      availability_zone   = string
    })
    localzone = object({
      vpc_id              = string
      vpc_cidr            = string
      regional_subnet_ids = list(string)
      edge_subnet_id      = string
      nat_public_ip       = string
      local_zone_name     = string
      parent_zone         = string
    })
    peering_connection_id = string
  })
}

variable "name_prefix" {
  description = "Prefix for the EKS cluster names (<prefix>-outposts, <prefix>-localzone)."
  type        = string
  default     = "eks"
}

variable "kubernetes_version" {
  description = "Kubernetes version for both clusters. Check it against your Istio version's support matrix."
  type        = string
  default     = "1.37"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the public EKS endpoints (your workstation or CI runners). Ignored when allow_public_api_from_anywhere is true."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "Each admin CIDR must be a valid IPv4 CIDR other than 0.0.0.0/0. To open the endpoints to everyone, set allow_public_api_from_anywhere = true instead."
  }

  validation {
    condition     = alltrue([for c in var.admin_cidrs : try(tonumber(split("/", c)[1]) >= 16, false)])
    error_message = "Each admin CIDR must be /16 or narrower (for example your egress IP as /32). Wide ranges such as 0.0.0.0/1 or 10.0.0.0/8 would expose the EKS API to everything inside them."
  }

  validation {
    # The public endpoint only ever sees public source IPs, so private, CGNAT, loopback, and
    # link-local ranges can never match and usually mean a mistake (for example a VPN's inner address).
    condition = alltrue([for c in var.admin_cidrs : !can(regex(
      "^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.|127\\.|169\\.254\\.)",
      try(cidrhost(c, 0), "")
    ))])
    error_message = "Admin CIDRs must be public addresses. The EKS public endpoint never sees private (10/8, 172.16/12, 192.168/16), CGNAT (100.64/10), loopback, or link-local sources; use your public egress IP (curl -s https://checkip.amazonaws.com)."
  }

  validation {
    condition     = length(var.admin_cidrs) > 0 || var.allow_public_api_from_anywhere
    error_message = "Provide at least one admin CIDR (your egress IP: curl -s https://checkip.amazonaws.com), or explicitly set allow_public_api_from_anywhere = true."
  }
}

variable "allow_public_api_from_anywhere" {
  description = "Lab only. Open both public EKS API endpoints to 0.0.0.0/0 instead of admin_cidrs plus the NAT IPs. The API still requires IAM authentication, but stolen credentials or remote-secret tokens then work from any IP. Never enable in production (see docs/security.md)."
  type        = bool
  default     = false
}

variable "outposts_nodes" {
  description = "Worker nodes on the Outposts. The instance type must be installed on the rack."
  type = object({
    instance_type    = optional(string, "m7i.xlarge")
    ami_architecture = optional(string, "x86_64")
    min_size         = optional(number, 1)
    max_size         = optional(number, 2)
    desired_size     = optional(number, 1)
    volume_type      = optional(string, "gp3")
    volume_size_gib  = optional(number, 100)
  })
  default = {}
}

variable "localzone_nodes" {
  description = "Worker nodes in the Local Zone. Many Local Zones offer only gp2 volumes and a subset of instance types."
  type = object({
    instance_type    = optional(string, "m6i.xlarge")
    ami_architecture = optional(string, "x86_64")
    min_size         = optional(number, 1)
    max_size         = optional(number, 2)
    desired_size     = optional(number, 1)
    volume_type      = optional(string, "gp2")
    volume_size_gib  = optional(number, 100)
  })
  default = {}
}

variable "kms_admin_principal_arns" {
  description = "IAM role or user ARNs (ArnLike wildcards allowed) that may manage both clusters' KMS keys. Empty (the default) means the role running Terraform. Every role that runs plan, apply, or destroy must match."
  type        = list(string)
  default     = []
}

variable "kms_deletion_window_days" {
  description = "Waiting period (7-30 days) before a deleted cluster KMS key is destroyed. Default 30, the maximum, to allow cancelling an accidental or malicious deletion."
  type        = number
  default     = 30
}

variable "bootstrap_cluster_creator_admin_permissions" {
  description = "Give the role that creates each cluster an implicit cluster-admin access entry. Set false with cluster_admin_principal_arns to separate deployment from administration. Changing it on existing clusters forces EKS to REPLACE both clusters; decide before the first apply."
  type        = bool
  default     = true
}

variable "cluster_admin_principal_arns" {
  description = "IAM role or user ARNs granted cluster admin (AmazonEKSClusterAdminPolicy) on both clusters, for example an admin and a break-glass role. With bootstrap_cluster_creator_admin_permissions = false, include the role that runs 30-mesh."
  type        = list(string)
  default     = []
}

variable "reader_token_alarm" {
  description = "CloudWatch alarm on each cluster's EKS audit log when its istio-reader token (shared with the peer istiod) is used from an IP other than the peer NAT gateway. alarm_actions are ARNs to notify, for example an SNS topic; with none, the alarm only changes state."
  type = object({
    enabled       = optional(bool, true)
    alarm_actions = optional(list(string), [])
  })
  default = {}
}

variable "tags" {
  description = "Extra tags applied to every resource through the provider default_tags."
  type        = map(string)
  default     = {}
}

variable "cleanup_cni_enis_on_destroy" {
  description = "On destroy, delete unattached VPC CNI ENIs left on the edge subnets so the node security groups can be deleted without manual steps."
  type        = bool
  default     = true
}
