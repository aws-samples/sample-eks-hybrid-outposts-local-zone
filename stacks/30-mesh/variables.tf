# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "clusters" {
  description = "Output of the 20-clusters stack. Written to clusters.auto.tfvars.json by scripts/export-outputs.sh."
  type = object({
    region = string
    outposts = object({
      name                       = string
      endpoint                   = string
      certificate_authority_data = string
      vpc_cidr                   = string
    })
    localzone = object({
      name                       = string
      endpoint                   = string
      certificate_authority_data = string
      vpc_cidr                   = string
    })
  })
}

variable "istio_version" {
  description = "Istio Helm chart version installed in both clusters."
  type        = string
  default     = "1.30.8"
}

variable "mesh_id" {
  description = "Istio mesh ID shared by both clusters."
  type        = string
  default     = "edge-mesh"
}

variable "create_cacerts" {
  description = "Generate the shared root and per-cluster intermediate CAs with Terraform (lab use). Set false if cacerts is provisioned another way, for example cert-manager with AWS Private CA."
  type        = bool
  default     = true
}

variable "enforce_strict_mtls" {
  description = "Apply a mesh-wide STRICT PeerAuthentication in both clusters."
  type        = bool
  default     = true
}

variable "gateway_node_selector" {
  description = "Label that marks the nodes running the east-west gateway (set by the eks-edge-cluster module)."
  type        = map(string)
  default     = { "edge-mesh.io/gateway" = "true" }
}

variable "remote_secret_token_rotation_days" {
  description = "Days before each istio-reader token in the remote secrets is replaced and the old token revoked. Rotation happens on the first apply after the period ends."
  type        = number
  default     = 30
}
