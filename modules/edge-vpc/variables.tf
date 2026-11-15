# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "name" {
  description = "Name used for the VPC and as a prefix for its resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{3,40}$", var.name))
    error_message = "name must be 3-40 characters of lowercase letters, digits, or hyphens."
  }
}

variable "cidr_block" {
  description = "IPv4 CIDR block for the VPC."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "cidr_block must be a valid IPv4 CIDR."
  }
}

variable "regional_subnets" {
  description = "Exactly two subnets in the parent Region. They host the EKS control plane ENIs and the NAT gateway."
  type = list(object({
    cidr              = string
    availability_zone = string
  }))

  validation {
    condition     = length(var.regional_subnets) == 2
    error_message = "Provide exactly two regional subnets (EKS requires subnets in at least two Availability Zones)."
  }

  validation {
    condition     = length(distinct([for s in var.regional_subnets : s.availability_zone])) == 2
    error_message = "The two regional subnets must be in different Availability Zones."
  }
}

variable "edge_type" {
  description = "Where the edge subnet lives: \"outposts\" (AWS Outposts rack) or \"localzone\" (AWS Local Zone)."
  type        = string

  validation {
    condition     = contains(["outposts", "localzone"], var.edge_type)
    error_message = "edge_type must be \"outposts\" or \"localzone\"."
  }
}

variable "edge_subnet_cidr" {
  description = "IPv4 CIDR for the edge subnet that hosts the EKS worker nodes."
  type        = string
}

variable "edge_availability_zone" {
  description = "Availability Zone of the edge subnet: the Outposts AZ, or the Local Zone name (for example us-east-1-mia-2)."
  type        = string
}

variable "outpost_arn" {
  description = "ARN of the Outposts. Required when edge_type is \"outposts\", must be null otherwise."
  type        = string
  default     = null

  validation {
    condition     = (var.edge_type == "outposts") == (var.outpost_arn != null)
    error_message = "outpost_arn is required when edge_type is \"outposts\" and must be null when edge_type is \"localzone\"."
  }
}

variable "flow_logs" {
  description = "VPC Flow Logs settings. kms_key_arn encrypts the log group; leave null to use the CloudWatch Logs default encryption."
  type = object({
    enabled        = optional(bool, true)
    retention_days = optional(number, 365)
    kms_key_arn    = optional(string)
  })
  default = {}
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
