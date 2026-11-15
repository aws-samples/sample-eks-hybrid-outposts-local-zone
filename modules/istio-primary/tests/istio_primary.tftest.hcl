# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

mock_provider "kubernetes" {}
mock_provider "helm" {}

variables {
  istio_version = "1.30.8"
  mesh_id       = "edge-mesh"
  cluster_name  = "cluster-outposts"
  network       = "network-outposts"
  mesh_networks = {
    network-outposts = { registry = "cluster-outposts", gateways = ["10.0.10.5"] }
    network-lz       = { registry = "cluster-lz", gateways = ["10.1.10.5", "10.1.10.6"] }
  }
  cacerts = {
    "ca-cert.pem"    = "intermediate"
    "ca-key.pem"     = "key"
    "root-cert.pem"  = "root"
    "cert-chain.pem" = "chain"
  }
}

run "istiod_values_define_the_multi_network_mesh" {
  command = apply

  assert {
    condition     = yamldecode(helm_release.istiod.values[0]).global.network == "network-outposts"
    error_message = "istiod must know its own network."
  }

  assert {
    condition     = yamldecode(helm_release.istiod.values[0]).global.multiCluster.clusterName == "cluster-outposts"
    error_message = "istiod must know its cluster name."
  }

  assert {
    condition     = yamldecode(helm_release.istiod.values[0]).global.meshID == "edge-mesh"
    error_message = "istiod must use the shared mesh ID."
  }

  assert {
    condition = (
      yamldecode(helm_release.istiod.values[0]).global.meshNetworks["network-lz"].gateways == [
        { address = "10.1.10.5", port = 15443 },
        { address = "10.1.10.6", port = 15443 },
      ]
    )
    error_message = "meshNetworks must list every peer gateway node IP on port 15443."
  }

  assert {
    condition     = yamldecode(helm_release.istiod.values[0]).global.meshNetworks["network-lz"].endpoints == [{ fromRegistry = "cluster-lz" }]
    error_message = "Peer endpoints must come from the peer cluster registry."
  }
}

run "gateway_injection_runs_without_sysctls" {
  command = apply

  assert {
    condition     = !contains(keys(yamldecode(helm_release.istiod.values[0]).gateways.securityContext), "sysctls")
    error_message = "The gateway only binds ports above 1024, so its security context must not add net.* sysctls."
  }
}

run "namespace_carries_the_network_label" {
  command = apply

  assert {
    condition     = kubernetes_namespace_v1.istio_system.metadata[0].labels["topology.istio.io/network"] == "network-outposts"
    error_message = "istio-system must be labelled with the cluster's network."
  }
}

run "plugged_in_ca_is_created_when_provided" {
  command = apply

  assert {
    condition     = length(kubernetes_secret_v1.cacerts) == 1 && kubernetes_secret_v1.cacerts[0].metadata[0].name == "cacerts"
    error_message = "The cacerts secret must be created when cacerts is provided."
  }
}

run "plugged_in_ca_is_skipped_when_external" {
  command = apply

  variables {
    cacerts = null
  }

  assert {
    condition     = length(kubernetes_secret_v1.cacerts) == 0
    error_message = "No cacerts secret should be created when the CA is managed elsewhere."
  }
}

run "eastwest_gateway_uses_the_local_chart" {
  command = apply

  assert {
    condition     = endswith(helm_release.eastwest_gateway.chart, "charts/eastwest-gateway")
    error_message = "The east-west gateway must come from the bundled chart."
  }

  assert {
    condition     = yamldecode(helm_release.eastwest_gateway.values[0]).network == "network-outposts"
    error_message = "The gateway must be told which network it serves."
  }

  assert {
    condition     = yamldecode(helm_release.eastwest_gateway.values[0]).enforceStrictMtls
    error_message = "STRICT mTLS should be on by default."
  }
}

run "charts_are_pinned" {
  command = apply

  assert {
    condition     = helm_release.base.version == "1.30.8" && helm_release.istiod.version == "1.30.8"
    error_message = "Istio charts must be pinned to istio_version."
  }
}

run "rejects_network_without_gateways" {
  command = plan

  variables {
    mesh_networks = {
      network-outposts = { registry = "cluster-outposts", gateways = ["10.0.10.5"] }
      network-lz       = { registry = "cluster-lz", gateways = [] }
    }
  }

  expect_failures = [var.mesh_networks]
}

run "rejects_unpinned_istio_version" {
  command = plan

  variables {
    istio_version = "latest"
  }

  expect_failures = [var.istio_version]
}
