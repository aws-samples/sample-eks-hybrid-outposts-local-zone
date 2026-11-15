# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Terraform equivalent of:
#   istioctl --context <source> create-remote-secret --name <source_cluster_name> \
#     | kubectl --context <target> apply -f -
#
# The token belongs to istio-reader-service-account (created by the Istio base
# chart, bound to a read-only ClusterRole by the istiod chart). The target
# cluster's istiod uses it to discover endpoints in the source cluster.
#
# That ClusterRole can get/list/watch Secrets in every namespace, and istiod
# needs it: it opens a cluster-wide Secret informer in every remote cluster
# (pilot/pkg/credentials/kube/multicluster.go), so the role cannot simply be
# narrowed. The token is therefore treated as a high-value credential:
#
# - It is rotated. Every token_rotation_days, the next apply creates a token
#   Secret with a new name, repoints the remote secret at it (istiod reloads
#   remote secrets without a restart), and then deletes the old token Secret.
#   Deleting a service-account-token Secret revokes its token.
# - Its use from anywhere but the peer NAT IP raises an alarm (see the
#   reader_token_alarm input of modules/eks-edge-cluster).

resource "time_rotating" "reader_token" {
  rotation_days = var.token_rotation_days
}

locals {
  secret_name = "istio-remote-secret-${var.source_cluster_name}" # pragma: allowlist secret -- resource name, not a credential

  # Changes on every rotation, which forces a new token Secret (and so a new token).
  token_secret_name = "istio-reader-token-${substr(sha256(time_rotating.reader_token.id), 0, 8)}" # pragma: allowlist secret -- resource name, not a credential

  kubeconfig = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    preferences     = {}
    current-context = var.source_cluster_name
    clusters = [{
      name = var.source_cluster_name
      cluster = {
        server                     = var.source_api_endpoint
        certificate-authority-data = var.source_ca_data
      }
    }]
    contexts = [{
      name = var.source_cluster_name
      context = {
        cluster = var.source_cluster_name
        user    = var.source_cluster_name
      }
    }]
    users = [{
      name = var.source_cluster_name
      user = { token = kubernetes_secret_v1.reader_token.data["token"] }
    }]
  })
}

resource "kubernetes_secret_v1" "reader_token" {
  provider = kubernetes.source

  metadata {
    name      = local.token_secret_name
    namespace = var.istio_namespace
    annotations = {
      "kubernetes.io/service-account.name" = var.reader_service_account
    }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true

  lifecycle {
    # Create the new token and update the remote secret before the old token is
    # deleted, so the peer istiod never holds a revoked token.
    create_before_destroy = true

    postcondition {
      condition     = contains(keys(self.data), "token")
      error_message = "Kubernetes did not populate a token for ${var.reader_service_account}. Check that the Istio base chart is installed in the source cluster."
    }
  }
}

resource "kubernetes_secret_v1" "remote" {
  provider = kubernetes.target

  metadata {
    name      = local.secret_name
    namespace = var.istio_namespace
    labels = {
      "istio/multiCluster" = "true"
    }
    annotations = {
      "networking.istio.io/cluster" = var.source_cluster_name
    }
  }

  data = {
    (var.source_cluster_name) = local.kubeconfig
  }
}
