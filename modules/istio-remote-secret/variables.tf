# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "source_cluster_name" {
  description = "Istio cluster name of the cluster being discovered (must match its global.multiCluster.clusterName)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.source_cluster_name))
    error_message = "source_cluster_name must be a valid DNS label (it is used in a Secret name and as a data key)."
  }
}

variable "source_api_endpoint" {
  description = "API server URL of the source cluster, reachable from the target cluster's istiod."
  type        = string

  validation {
    condition     = startswith(var.source_api_endpoint, "https://")
    error_message = "source_api_endpoint must be an https:// URL."
  }
}

variable "source_ca_data" {
  description = "Base64-encoded CA certificate of the source cluster API server."
  type        = string
}

variable "istio_namespace" {
  description = "Istio root namespace in both clusters."
  type        = string
  default     = "istio-system"
}

variable "reader_service_account" {
  description = "Service account in the source cluster whose token is shared."
  type        = string
  default     = "istio-reader-service-account"
}

variable "token_rotation_days" {
  description = "Days before the reader token is replaced and the old one revoked. Rotation happens on the first apply after the period ends, so apply the mesh stack at least this often."
  type        = number
  default     = 30

  validation {
    condition     = var.token_rotation_days >= 1 && var.token_rotation_days <= 365 && floor(var.token_rotation_days) == var.token_rotation_days
    error_message = "token_rotation_days must be a whole number from 1 to 365."
  }
}
