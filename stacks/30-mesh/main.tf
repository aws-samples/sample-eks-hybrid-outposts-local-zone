# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  mesh = {
    outposts = {
      cluster_name = "cluster-outposts"
      network      = "network-outposts"
    }
    localzone = {
      cluster_name = "cluster-lz"
      network      = "network-lz"
    }
  }

  gateway_ips = {
    outposts  = local.outposts_gateway_ips
    localzone = local.localzone_gateway_ips
  }

  outposts_gateway_ips = sort(flatten([
    for node in data.kubernetes_nodes.outposts_gateways.nodes : [
      for addr in node.status[0].addresses : addr.address if addr.type == "InternalIP"
    ]
  ]))

  localzone_gateway_ips = sort(flatten([
    for node in data.kubernetes_nodes.localzone_gateways.nodes : [
      for addr in node.status[0].addresses : addr.address if addr.type == "InternalIP"
    ]
  ]))

  # Identical in both clusters: each network's endpoints come from its own
  # cluster registry and are reached through that network's gateway node IPs.
  mesh_networks = {
    for k, m in local.mesh : m.network => {
      registry = m.cluster_name
      gateways = local.gateway_ips[k]
    }
  }
}

# ---------------------------------------------------------------------------
# Gateway node discovery
# ---------------------------------------------------------------------------

data "kubernetes_nodes" "outposts_gateways" {
  provider = kubernetes.outposts

  metadata {
    labels = var.gateway_node_selector
  }
}

data "kubernetes_nodes" "localzone_gateways" {
  provider = kubernetes.localzone

  metadata {
    labels = var.gateway_node_selector
  }
}

check "gateway_nodes_present" {
  assert {
    condition     = length(local.outposts_gateway_ips) > 0 && length(local.localzone_gateway_ips) > 0
    error_message = "No gateway nodes found in one of the clusters. Run scripts/wait-for-nodes.sh, then re-run this stack."
  }
}

# ---------------------------------------------------------------------------
# Shared trust
# ---------------------------------------------------------------------------

module "mesh_ca" {
  source = "../../modules/mesh-ca"
  count  = var.create_cacerts ? 1 : 0

  mesh_id       = var.mesh_id
  cluster_names = [for m in values(local.mesh) : m.cluster_name]
}

# ---------------------------------------------------------------------------
# Istio primaries
# ---------------------------------------------------------------------------

module "istio_outposts" {
  source = "../../modules/istio-primary"

  providers = {
    kubernetes = kubernetes.outposts
    helm       = helm.outposts
  }

  istio_version         = var.istio_version
  mesh_id               = var.mesh_id
  cluster_name          = local.mesh.outposts.cluster_name
  network               = local.mesh.outposts.network
  mesh_networks         = local.mesh_networks
  cacerts               = var.create_cacerts ? module.mesh_ca[0].cacerts[local.mesh.outposts.cluster_name] : null
  gateway_node_selector = var.gateway_node_selector
  enforce_strict_mtls   = var.enforce_strict_mtls
}

module "istio_localzone" {
  source = "../../modules/istio-primary"

  providers = {
    kubernetes = kubernetes.localzone
    helm       = helm.localzone
  }

  istio_version         = var.istio_version
  mesh_id               = var.mesh_id
  cluster_name          = local.mesh.localzone.cluster_name
  network               = local.mesh.localzone.network
  mesh_networks         = local.mesh_networks
  cacerts               = var.create_cacerts ? module.mesh_ca[0].cacerts[local.mesh.localzone.cluster_name] : null
  gateway_node_selector = var.gateway_node_selector
  enforce_strict_mtls   = var.enforce_strict_mtls
}

# ---------------------------------------------------------------------------
# Cross-cluster endpoint discovery (remote secrets in both directions)
# ---------------------------------------------------------------------------

module "remote_secret_localzone_in_outposts" {
  source = "../../modules/istio-remote-secret"

  providers = {
    kubernetes.source = kubernetes.localzone
    kubernetes.target = kubernetes.outposts
  }

  source_cluster_name = local.mesh.localzone.cluster_name
  source_api_endpoint = var.clusters.localzone.endpoint
  source_ca_data      = var.clusters.localzone.certificate_authority_data
  token_rotation_days = var.remote_secret_token_rotation_days

  depends_on = [module.istio_outposts, module.istio_localzone]
}

module "remote_secret_outposts_in_localzone" {
  source = "../../modules/istio-remote-secret"

  providers = {
    kubernetes.source = kubernetes.outposts
    kubernetes.target = kubernetes.localzone
  }

  source_cluster_name = local.mesh.outposts.cluster_name
  source_api_endpoint = var.clusters.outposts.endpoint
  source_ca_data      = var.clusters.outposts.certificate_authority_data
  token_rotation_days = var.remote_secret_token_rotation_days

  depends_on = [module.istio_outposts, module.istio_localzone]
}
