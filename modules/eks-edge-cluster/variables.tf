# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "name" {
  description = "EKS cluster name."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,99}$", var.name))
    error_message = "name must start with a letter and contain only letters, digits, and hyphens (max 100)."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version for the control plane and the node AMI (for example \"1.37\")."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must look like \"1.37\"."
  }
}

variable "location" {
  description = "Edge location type of the worker nodes: \"outposts\" or \"localzone\"."
  type        = string

  validation {
    condition     = contains(["outposts", "localzone"], var.location)
    error_message = "location must be \"outposts\" or \"localzone\"."
  }
}

variable "vpc_id" {
  description = "VPC that hosts the cluster."
  type        = string
}

variable "control_plane_subnet_ids" {
  description = "Regional subnets (two AZs) for the EKS control plane ENIs."
  type        = list(string)

  validation {
    condition     = length(var.control_plane_subnet_ids) >= 2
    error_message = "EKS needs control plane subnets in at least two Availability Zones."
  }
}

variable "edge_subnet_id" {
  description = "Outposts or Local Zone subnet for the self-managed worker nodes."
  type        = string
}

variable "outpost_arn" {
  description = "Outposts ARN. Required when location is \"outposts\"; used to check that the instance type is installed on the rack."
  type        = string
  default     = null

  validation {
    condition     = (var.location == "outposts") == (var.outpost_arn != null)
    error_message = "outpost_arn is required when location is \"outposts\" and must be null otherwise."
  }
}

variable "local_zone_name" {
  description = "Local Zone name (for example us-east-1-mia-2). Required when location is \"localzone\"."
  type        = string
  default     = null

  validation {
    condition     = (var.location == "localzone") == (var.local_zone_name != null)
    error_message = "local_zone_name is required when location is \"localzone\" and must be null otherwise."
  }
}

variable "service_ipv4_cidr" {
  description = "Kubernetes Service CIDR. Must not overlap the VPC CIDRs or any peer network."
  type        = string
  default     = "172.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.service_ipv4_cidr, 0))
    error_message = "service_ipv4_cidr must be a valid IPv4 CIDR."
  }
}

variable "peer_cidrs" {
  description = "CIDRs of peer mesh networks. They are allowed to reach the east-west gateway (TCP 15443) and ICMP."
  type        = list(string)
  default     = []
}

variable "endpoint_public_access" {
  description = "Expose the EKS API server publicly (restricted to endpoint_public_access_cidrs). The private endpoint is always on."
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS endpoint. Include your admin IP and the NAT IPs of peer VPCs (the peer istiod watches this API)."
  type        = list(string)

  validation {
    condition     = !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0") || var.allow_public_access_anywhere
    error_message = "Do not open the EKS public endpoint to 0.0.0.0/0. List your admin CIDRs and the peer NAT IPs instead, or set allow_public_access_anywhere = true for a lab."
  }

  validation {
    # Blocks near-world ranges such as 0.0.0.0/1 that the 0.0.0.0/0 check above would miss.
    condition     = alltrue([for c in var.endpoint_public_access_cidrs : c == "0.0.0.0/0" || try(tonumber(split("/", c)[1]) >= 16, false)])
    error_message = "Each endpoint_public_access_cidrs entry must be a CIDR of /16 or narrower (0.0.0.0/0 is only allowed with allow_public_access_anywhere)."
  }
}

variable "kms_deletion_window_days" {
  description = "Waiting period before a deleted KMS key is destroyed. 30 (the maximum) gives the most time to cancel an accidental or malicious deletion."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30 && floor(var.kms_deletion_window_days) == var.kms_deletion_window_days
    error_message = "kms_deletion_window_days must be a whole number from 7 to 30."
  }
}

variable "bootstrap_cluster_creator_admin_permissions" {
  description = "Give the IAM principal that creates the cluster an implicit cluster-admin access entry. Set false (together with cluster_admin_principal_arns) to separate deployment from administration. Changing this on an existing cluster forces EKS to replace the cluster."
  type        = bool
  default     = true
}

variable "cluster_admin_principal_arns" {
  description = "IAM role or user ARNs granted AmazonEKSClusterAdminPolicy (cluster scope) through access entries, for example your admin and break-glass roles. With bootstrap_cluster_creator_admin_permissions = false, include the role that runs the 30-mesh stack. Do not list the cluster creator while bootstrap is true (EKS already created its entry)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.cluster_admin_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/[^*?]+$", a))])
    error_message = "Each entry must be an IAM role or user ARN (no wildcards; access entries need an exact principal)."
  }

  validation {
    condition     = var.bootstrap_cluster_creator_admin_permissions || length(var.cluster_admin_principal_arns) > 0
    error_message = "With bootstrap_cluster_creator_admin_permissions = false, list at least one cluster_admin_principal_arns entry, or nobody can administer the cluster."
  }
}

variable "allow_public_access_anywhere" {
  description = "Lab only. Permit 0.0.0.0/0 in endpoint_public_access_cidrs. IAM authentication still applies, but the API becomes reachable from any IP."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "EC2 instance type for the worker nodes. It must be installed on the Outposts or offered in the Local Zone."
  type        = string
}

variable "ami_architecture" {
  description = "Architecture of the EKS-optimized Amazon Linux 2023 AMI: x86_64 or arm64."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.ami_architecture)
    error_message = "ami_architecture must be x86_64 or arm64."
  }
}

variable "node_group" {
  description = "Auto Scaling group size for the worker nodes."
  type = object({
    min_size     = optional(number, 1)
    max_size     = optional(number, 2)
    desired_size = optional(number, 1)
  })
  default = {}

  validation {
    condition     = var.node_group.min_size <= var.node_group.desired_size && var.node_group.desired_size <= var.node_group.max_size
    error_message = "node_group must satisfy min_size <= desired_size <= max_size."
  }
}

variable "root_volume" {
  description = "Root EBS volume. Check which volume types your Outposts or Local Zone supports (many Local Zones support only gp2)."
  type = object({
    size_gib = optional(number, 100)
    type     = optional(string, "gp2")
  })
  default = {}

  validation {
    condition     = contains(["gp2", "gp3", "io1", "io2"], var.root_volume.type)
    error_message = "root_volume.type must be gp2, gp3, io1, or io2."
  }
}

variable "imds_hop_limit" {
  description = "IMDSv2 hop limit. 1 blocks Pods without host networking from reaching instance credentials."
  type        = number
  default     = 1
}

variable "node_labels" {
  description = "Extra Kubernetes labels applied to the nodes through kubelet."
  type        = map(string)
  default     = {}
}

variable "cluster_log_types" {
  description = "EKS control plane log types sent to CloudWatch Logs."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "log_retention_days" {
  description = "Retention for the control plane log group."
  type        = number
  default     = 365
}

variable "kms_admin_principal_arns" {
  description = "IAM role or user ARNs (ArnLike wildcards allowed) that may manage the cluster KMS key. Empty (the default) means the role running Terraform. Every role that runs plan, apply, or destroy must match."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.kms_admin_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root|role/.+|user/.+)$", a))])
    error_message = "Each entry must be an IAM role or user ARN (wildcards allowed, for example AWSReservedSSO_Admin_*), or the account root user."
  }
}

variable "reader_token_alarm" {
  description = "Alarm when the istio-reader token is used from any IP other than allowed_source_ips (the peer NAT IPs). Needs the audit log type. Null disables it."
  type = object({
    allowed_source_ips = list(string)
    alarm_actions      = optional(list(string), [])
    username           = optional(string, "system:serviceaccount:istio-system:istio-reader-service-account")
  })
  default = null

  validation {
    condition = var.reader_token_alarm == null || (
      length(var.reader_token_alarm.allowed_source_ips) > 0 &&
      alltrue([for ip in var.reader_token_alarm.allowed_source_ips : can(cidrhost("${ip}/32", 0))])
    )
    error_message = "reader_token_alarm.allowed_source_ips must hold at least one IPv4 address (no CIDR suffix)."
  }

  validation {
    condition     = var.reader_token_alarm == null || alltrue([for a in var.reader_token_alarm.alarm_actions : startswith(a, "arn:")])
    error_message = "reader_token_alarm.alarm_actions must be ARNs (for example an SNS topic)."
  }

  validation {
    condition     = var.reader_token_alarm == null || contains(var.cluster_log_types, "audit")
    error_message = "reader_token_alarm reads the EKS audit log, so cluster_log_types must include \"audit\"."
  }
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "cleanup_cni_enis_on_destroy" {
  description = "On destroy, delete unattached VPC CNI ENIs of this cluster (and wait for the rest to detach) before deleting the node security group. Runs the aws CLI locally with the same credentials as Terraform."
  type        = bool
  default     = true
}
