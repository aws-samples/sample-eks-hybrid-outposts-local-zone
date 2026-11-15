# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "namespace" {
  description = "Namespace where Istio is installed."
  value       = kubernetes_namespace_v1.istio_system.metadata[0].name
}

output "istiod_values" {
  description = "Rendered istiod Helm values (useful for review and tests)."
  value       = local.istiod_values
}

output "release_status" {
  description = "Helm release status for each Istio component."
  value = {
    base             = helm_release.base.status
    istiod           = helm_release.istiod.status
    eastwest_gateway = helm_release.eastwest_gateway.status
  }
}
