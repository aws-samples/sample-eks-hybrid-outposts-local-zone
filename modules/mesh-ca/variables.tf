# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "mesh_id" {
  description = "Istio mesh ID, used in the root CA common name."
  type        = string
}

variable "cluster_names" {
  description = "Istio cluster names. One intermediate CA is issued per name."
  type        = list(string)

  validation {
    condition     = length(var.cluster_names) >= 2 && length(distinct(var.cluster_names)) == length(var.cluster_names)
    error_message = "Provide at least two unique cluster names."
  }
}

variable "organization" {
  description = "Organization (O) in the certificate subjects."
  type        = string
  default     = "Istio"
}

variable "root_validity_hours" {
  description = "Root CA validity. Default: 10 years."
  type        = number
  default     = 87600
}

variable "intermediate_validity_hours" {
  description = "Intermediate CA validity. Default: 2 years. Must be shorter than the root."
  type        = number
  default     = 17520

  validation {
    condition     = var.intermediate_validity_hours < var.root_validity_hours
    error_message = "intermediate_validity_hours must be shorter than root_validity_hours."
  }
}
