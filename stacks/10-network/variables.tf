# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "region" {
  description = "Parent AWS Region of the Outposts and the Local Zone."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "edge-mesh"
}

variable "outpost_arn" {
  description = "ARN of the Outposts rack (aws outposts list-outposts)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:outposts:[a-z0-9-]+:[0-9]{12}:outpost/op-[0-9a-f]{17}$", var.outpost_arn))
    error_message = "outpost_arn must look like arn:aws:outposts:<region>:<account>:outpost/op-0123456789abcdef0."
  }
}

variable "local_zone_name" {
  description = "Local Zone name, for example us-east-1-mia-2."
  type        = string
}

variable "manage_local_zone_opt_in" {
  description = "Opt the Local Zone group in. Terraform cannot opt out on destroy; it only removes the resource from state."
  type        = bool
  default     = true
}

variable "cidrs" {
  description = "Address plan. The two VPC CIDRs must not overlap."
  type = object({
    outposts = object({
      vpc      = string
      regional = list(string)
      edge     = string
    })
    localzone = object({
      vpc      = string
      regional = list(string)
      edge     = string
    })
  })
  default = {
    outposts = {
      vpc      = "10.3.0.0/16"
      regional = ["10.3.1.0/24", "10.3.2.0/24"]
      edge     = "10.3.10.0/24"
    }
    localzone = {
      vpc      = "10.2.0.0/16"
      regional = ["10.2.1.0/24", "10.2.2.0/24"]
      edge     = "10.2.10.0/24"
    }
  }

  validation {
    condition     = var.cidrs.outposts.vpc != var.cidrs.localzone.vpc
    error_message = "The Outposts and Local Zone VPC CIDRs must differ."
  }
}

variable "enable_flow_logs" {
  description = "Send VPC Flow Logs for both VPCs to CloudWatch Logs (KMS-encrypted)."
  type        = bool
  default     = true
}

variable "kms_admin_principal_arns" {
  description = "IAM role or user ARNs (ArnLike wildcards allowed) that may manage the flow logs KMS key. Empty (the default) means the role running Terraform. Every role that runs plan, apply, or destroy must match."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.kms_admin_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root|role/.+|user/.+)$", a))])
    error_message = "Each entry must be an IAM role or user ARN (wildcards allowed, for example AWSReservedSSO_Admin_*), or the account root user."
  }
}

variable "kms_deletion_window_days" {
  description = "Waiting period before a deleted flow logs KMS key is destroyed. 30 (the maximum) gives the most time to cancel an accidental or malicious deletion."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30 && floor(var.kms_deletion_window_days) == var.kms_deletion_window_days
    error_message = "kms_deletion_window_days must be a whole number from 7 to 30."
  }
}

variable "tags" {
  description = "Extra tags applied to every resource through the provider default_tags."
  type        = map(string)
  default     = {}
}
