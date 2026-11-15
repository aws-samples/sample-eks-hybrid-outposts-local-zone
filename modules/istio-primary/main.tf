# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  namespace = "istio-system"

  # Network Load Balancers are not available on Outposts subnets, so the
  # east-west gateway publishes 15443 on the node IP (hostPort) and each network advertises its
  # node IPs directly. Setting meshNetworks through the istiod chart replaces
  # the manual ConfigMap patch and istiod restart.
  mesh_networks = {
    for network, cfg in var.mesh_networks : network => {
      endpoints = [{ fromRegistry = cfg.registry }]
      gateways  = [for ip in cfg.gateways : { address = ip, port = cfg.port }]
    }
  }

  istiod_values = {
    global = {
      meshID       = var.mesh_id
      network      = var.network
      multiCluster = { clusterName = var.cluster_name }
      meshNetworks = local.mesh_networks
    }
    meshConfig = {
      accessLogFile = var.access_log_file
    }
    env = {
      # Accept peers whose certificates chain to a different intermediate.
      ISTIO_MULTIROOT_MESH = "true"
      # Pick up a rotated cacerts secret without restarting istiod.
      AUTO_RELOAD_PLUGIN_CERTS = "true"
    }
    resources = {
      requests = var.istiod_resources
    }
    # The default gateway injection template adds the net.ipv4.ip_unprivileged_port_start
    # sysctl so a gateway can bind ports below 1024. The east-west gateway only binds
    # 15021 and 15443, so a plain non-root security context is enough.
    gateways = {
      securityContext = {
        runAsNonRoot   = true
        seccompProfile = { type = "RuntimeDefault" }
      }
    }
  }

  gateway_values = {
    network             = var.network
    nodeSelector        = var.gateway_node_selector
    enforceStrictMtls   = var.enforce_strict_mtls
    crossNetworkGateway = { enabled = true }
  }
}

resource "kubernetes_namespace_v1" "istio_system" {
  metadata {
    name = local.namespace
    labels = {
      "topology.istio.io/network" = var.network
    }
  }
}

resource "kubernetes_secret_v1" "cacerts" {
  count = var.cacerts == null ? 0 : 1

  metadata {
    name      = "cacerts"
    namespace = kubernetes_namespace_v1.istio_system.metadata[0].name
  }

  data = var.cacerts
}

resource "helm_release" "base" {
  name       = "istio-base"
  repository = var.chart_repository
  chart      = "base"
  version    = var.istio_version
  namespace  = kubernetes_namespace_v1.istio_system.metadata[0].name

  values = [yamlencode({ defaultRevision = "default" })]
}

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = var.chart_repository
  chart      = "istiod"
  version    = var.istio_version
  namespace  = kubernetes_namespace_v1.istio_system.metadata[0].name
  wait       = true
  timeout    = 600

  values = [yamlencode(local.istiod_values)]

  depends_on = [
    helm_release.base,
    kubernetes_secret_v1.cacerts,
  ]
}

resource "helm_release" "eastwest_gateway" {
  name      = "istio-eastwestgateway"
  chart     = "${path.module}/charts/eastwest-gateway"
  namespace = kubernetes_namespace_v1.istio_system.metadata[0].name
  wait      = true
  timeout   = 600

  values = [yamlencode(local.gateway_values)]

  # The gateway relies on istiod's injection webhook and on the Istio CRDs.
  depends_on = [helm_release.istiod]
}
