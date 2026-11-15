# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "mesh" {
  description = "Mesh topology as installed."
  value = {
    mesh_id       = var.mesh_id
    istio_version = var.istio_version
    networks = {
      for k, m in local.mesh : m.network => {
        cluster     = m.cluster_name
        eks_cluster = var.clusters[k].name
        gateways    = [for ip in local.gateway_ips[k] : "${ip}:15443"]
      }
    }
  }
}

output "remote_secrets" {
  description = "Remote secrets created for cross-cluster endpoint discovery."
  value = {
    (var.clusters.outposts.name)  = module.remote_secret_localzone_in_outposts.secret_name
    (var.clusters.localzone.name) = module.remote_secret_outposts_in_localzone.secret_name
  }
}

output "remote_secret_tokens_rotate_at" {
  description = "When each cluster's istio-reader token is next replaced and revoked (on the first apply after this time), keyed by the cluster that issues it."
  value = {
    (var.clusters.localzone.name) = module.remote_secret_localzone_in_outposts.token_rotates_at
    (var.clusters.outposts.name)  = module.remote_secret_outposts_in_localzone.token_rotates_at
  }
}
