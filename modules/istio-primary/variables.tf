# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "istio_version" {
  description = "Istio Helm chart version (base, istiod)."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]+\\.[0-9]+$", var.istio_version))
    error_message = "istio_version must be a full release such as 1.30.8."
  }
}

variable "chart_repository" {
  description = "Helm repository that hosts the Istio charts."
  type        = string
  default     = "https://istio-release.storage.googleapis.com/charts"
}

variable "mesh_id" {
  description = "Mesh ID shared by every cluster in the mesh."
  type        = string
}

variable "cluster_name" {
  description = "Istio cluster name of this primary (for example cluster-outposts)."
  type        = string
}

variable "network" {
  description = "Istio network name of this cluster (for example network-outposts)."
  type        = string
}

variable "mesh_networks" {
  description = "meshNetworks for every network in the mesh: endpoints come from a cluster registry, gateways are the IPs of the nodes publishing the gateway hostPort."
  type = map(object({
    registry = string
    gateways = list(string)
    port     = optional(number, 15443)
  }))

  validation {
    condition     = alltrue([for n in values(var.mesh_networks) : length(n.gateways) > 0])
    error_message = "Every mesh network needs at least one gateway address."
  }
}

variable "cacerts" {
  description = "Plugged-in CA for this cluster (ca-cert.pem, ca-key.pem, root-cert.pem, cert-chain.pem). Null if the cacerts secret is managed elsewhere (for example cert-manager with AWS Private CA)."
  type        = map(string)
  default     = null
  sensitive   = true
}

variable "gateway_node_selector" {
  description = "Node labels that select the nodes running the east-west gateway."
  type        = map(string)
  default     = { "edge-mesh.io/gateway" = "true" }
}

variable "enforce_strict_mtls" {
  description = "Apply a mesh-wide STRICT PeerAuthentication."
  type        = bool
  default     = true
}

variable "access_log_file" {
  description = "Envoy access log destination. Empty string disables access logs."
  type        = string
  default     = "/dev/stdout"
}

variable "istiod_resources" {
  description = "Resource requests for istiod. Size them for the edge nodes."
  type = object({
    cpu    = optional(string, "250m")
    memory = optional(string, "512Mi")
  })
  default = {}
}
