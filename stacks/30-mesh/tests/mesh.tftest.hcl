# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Wiring tests for the mesh stack. Kubernetes and Helm are mocked; the tls
# provider is real, so the CA bundles are genuine.

mock_provider "kubernetes" {
  alias = "outposts"

  mock_data "kubernetes_nodes" {
    defaults = {
      nodes = [{
        metadata = [{ name = "ip-10-0-10-5", labels = { "edge-mesh.io/gateway" = "true" } }]
        status = [{
          addresses = [
            { type = "InternalIP", address = "10.3.10.5" },
            { type = "Hostname", address = "ip-10-0-10-5.ec2.internal" },
          ]
        }]
      }]
    }
  }
}

mock_provider "kubernetes" {
  alias = "localzone"

  mock_data "kubernetes_nodes" {
    defaults = {
      nodes = [{
        metadata = [{ name = "ip-10-1-10-5", labels = { "edge-mesh.io/gateway" = "true" } }]
        status = [{
          addresses = [
            { type = "InternalIP", address = "10.2.10.5" },
          ]
        }]
      }]
    }
  }
}

mock_provider "helm" {
  alias = "outposts"
}

mock_provider "helm" {
  alias = "localzone"
}

override_resource {
  target = module.remote_secret_localzone_in_outposts.kubernetes_secret_v1.reader_token
  # checkov:skip=CKV_SECRET_6:Test fixture, not a credential
  values = { data = { token = "lz-reader-token" } }
}

override_resource {
  target = module.remote_secret_outposts_in_localzone.kubernetes_secret_v1.reader_token
  # checkov:skip=CKV_SECRET_6:Test fixture, not a credential
  values = { data = { token = "outposts-reader-token" } }
}

variables {
  clusters = {
    region = "us-east-1"
    outposts = {
      name                       = "eks-outposts"
      endpoint                   = "https://OUTPOSTS.gr7.us-east-1.eks.amazonaws.com"
      certificate_authority_data = "LS0tLS1CRUdJTi0tLS0t"
      vpc_cidr                   = "10.3.0.0/16"
    }
    localzone = {
      name                       = "eks-localzone"
      endpoint                   = "https://LOCALZONE.gr7.us-east-1.eks.amazonaws.com"
      certificate_authority_data = "LS0tLS1CRUdJTi0tLS0t"
      vpc_cidr                   = "10.2.0.0/16"
    }
  }
}

run "gateway_ips_come_from_node_internal_ips" {
  command = apply

  assert {
    condition     = local.outposts_gateway_ips == tolist(["10.3.10.5"]) && local.localzone_gateway_ips == tolist(["10.2.10.5"])
    error_message = "Only InternalIP addresses of gateway-labelled nodes may be advertised."
  }
}

run "both_clusters_share_the_same_mesh_networks" {
  command = apply

  assert {
    condition     = module.istio_outposts.istiod_values.global.meshNetworks == module.istio_localzone.istiod_values.global.meshNetworks
    error_message = "meshNetworks must be identical in both primaries."
  }

  assert {
    condition     = module.istio_outposts.istiod_values.global.meshNetworks["network-lz"].gateways == [{ address = "10.2.10.5", port = 15443 }]
    error_message = "The Outposts primary must reach network-lz through the Local Zone node IP."
  }

  assert {
    condition     = module.istio_localzone.istiod_values.global.meshNetworks["network-outposts"].endpoints == [{ fromRegistry = "cluster-outposts" }]
    error_message = "network-outposts endpoints must come from the cluster-outposts registry."
  }
}

run "each_primary_has_its_own_identity" {
  command = apply

  assert {
    condition     = module.istio_outposts.istiod_values.global.network == "network-outposts" && module.istio_localzone.istiod_values.global.network == "network-lz"
    error_message = "Each primary must be on its own network."
  }

  assert {
    condition     = module.istio_outposts.istiod_values.global.meshID == module.istio_localzone.istiod_values.global.meshID
    error_message = "Both primaries must share the mesh ID."
  }
}

run "remote_secrets_point_in_both_directions" {
  command = apply

  assert {
    condition = output.remote_secrets == {
      "eks-outposts"  = "istio-remote-secret-cluster-lz"
      "eks-localzone" = "istio-remote-secret-cluster-outposts"
    }
    error_message = "Each cluster must hold a remote secret for the other."
  }
}

run "external_ca_mode_skips_generated_certificates" {
  command = apply

  variables {
    create_cacerts = false
  }

  assert {
    condition     = length(module.mesh_ca) == 0
    error_message = "create_cacerts = false must not generate CA material."
  }
}
