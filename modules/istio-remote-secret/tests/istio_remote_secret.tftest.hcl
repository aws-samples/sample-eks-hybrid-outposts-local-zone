# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

mock_provider "kubernetes" {
  alias = "source"
}

mock_provider "kubernetes" {
  alias = "target"
}

mock_provider "time" {}

override_resource {
  target = time_rotating.reader_token
  values = {
    id               = "2026-01-01T00:00:00Z"
    rotation_rfc3339 = "2026-01-31T00:00:00Z"
  }
}

override_resource {
  target = kubernetes_secret_v1.reader_token
  values = {
    # checkov:skip=CKV_SECRET_6:Test fixture, not a credential
    data = { token = "test-reader-token" }
  }
}

variables {
  source_cluster_name = "cluster-lz"
  source_api_endpoint = "https://ABCDEF.gr7.us-east-1.eks.amazonaws.com"
  # checkov:skip=CKV_SECRET_6:Test fixture, not a credential
  source_ca_data = "LS0tLS1CRUdJTi0tLS0t"
}

run "remote_secret_matches_istioctl_format" {
  command = apply

  providers = {
    kubernetes.source = kubernetes.source
    kubernetes.target = kubernetes.target
  }

  assert {
    condition     = kubernetes_secret_v1.remote.metadata[0].name == "istio-remote-secret-cluster-lz"
    error_message = "Secret name must follow istioctl's istio-remote-secret-<cluster> convention."
  }

  assert {
    condition     = kubernetes_secret_v1.remote.metadata[0].labels["istio/multiCluster"] == "true"
    error_message = "istiod only watches secrets labelled istio/multiCluster=true."
  }

  assert {
    condition     = kubernetes_secret_v1.remote.metadata[0].annotations["networking.istio.io/cluster"] == "cluster-lz"
    error_message = "The cluster annotation must match the source cluster name."
  }
}

run "kubeconfig_points_at_the_source_cluster" {
  command = apply

  providers = {
    kubernetes.source = kubernetes.source
    kubernetes.target = kubernetes.target
  }

  assert {
    condition     = yamldecode(kubernetes_secret_v1.remote.data["cluster-lz"]).clusters[0].cluster.server == var.source_api_endpoint
    error_message = "The kubeconfig must target the source API endpoint."
  }

  assert {
    # checkov:skip=CKV_SECRET_6:Test fixture, not a credential
    condition     = yamldecode(kubernetes_secret_v1.remote.data["cluster-lz"]).users[0].user.token == "test-reader-token"
    error_message = "The kubeconfig must carry the reader service account token."
  }

  assert {
    condition     = kubernetes_secret_v1.reader_token.metadata[0].annotations["kubernetes.io/service-account.name"] == "istio-reader-service-account"
    error_message = "The token must belong to the read-only istio-reader-service-account."
  }
}

run "token_rotates_on_a_schedule" {
  command = apply

  providers = {
    kubernetes.source = kubernetes.source
    kubernetes.target = kubernetes.target
    time              = time
  }

  assert {
    condition     = time_rotating.reader_token.rotation_days == 30
    error_message = "The reader token must rotate every 30 days by default."
  }

  assert {
    condition     = can(regex("^istio-reader-token-[0-9a-f]{8}$", kubernetes_secret_v1.reader_token.metadata[0].name))
    error_message = "The token Secret name must carry a rotation suffix so each rotation creates a new token."
  }

  assert {
    condition     = output.token_rotates_at == "2026-01-31T00:00:00Z"
    error_message = "The module must expose when the token next rotates."
  }
}

run "rotation_creates_a_new_token_secret" {
  command = apply
  # Separate state: models the next rotation period instead of reusing the first run's resources.
  state_key = "next_rotation"

  providers = {
    kubernetes.source = kubernetes.source
    kubernetes.target = kubernetes.target
    time              = time
  }

  override_resource {
    target = time_rotating.reader_token
    values = {
      id               = "2026-01-31T00:00:00Z"
      rotation_rfc3339 = "2026-03-02T00:00:00Z"
    }
  }

  assert {
    condition     = output.token_secret_name != run.token_rotates_on_a_schedule.token_secret_name
    error_message = "A new rotation period must produce a differently named token Secret (the old one is deleted, revoking its token)."
  }
}

run "rejects_invalid_rotation_period" {
  command = plan

  providers = {
    kubernetes.source = kubernetes.source
    kubernetes.target = kubernetes.target
    time              = time
  }

  variables {
    token_rotation_days = 0
  }

  expect_failures = [var.token_rotation_days]
}

run "rejects_plain_http_endpoint" {
  command = plan

  providers = {
    kubernetes.source = kubernetes.source
    kubernetes.target = kubernetes.target
  }

  variables {
    source_api_endpoint = "http://insecure.example.com"
  }

  expect_failures = [var.source_api_endpoint]
}
