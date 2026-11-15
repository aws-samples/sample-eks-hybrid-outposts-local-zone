# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "name" {
  description = "Name tag for the peering connection."
  type        = string
}

variable "requester" {
  description = "Requester VPC. route_table_ids is a map with static keys (for example regional, edge) so it can drive for_each."
  type = object({
    vpc_id          = string
    cidr            = string
    route_table_ids = map(string)
  })
}

variable "accepter" {
  description = "Accepter VPC, in the same account and Region as the requester."
  type = object({
    vpc_id          = string
    cidr            = string
    route_table_ids = map(string)
  })

  validation {
    condition     = var.accepter.cidr != var.requester.cidr
    error_message = "Peered VPCs must have different CIDR blocks."
  }
}

variable "tags" {
  description = "Tags applied to the peering connection."
  type        = map(string)
  default     = {}
}
