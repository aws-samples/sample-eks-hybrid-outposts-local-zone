# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "root_cert_pem" {
  description = "Shared root CA certificate."
  value       = tls_self_signed_cert.root.cert_pem
}

output "cacerts" {
  description = "Per-cluster contents of the Istio cacerts secret, keyed by cluster name."
  sensitive   = true
  value = {
    for name in var.cluster_names : name => {
      "ca-cert.pem"    = tls_locally_signed_cert.intermediate[name].cert_pem
      "ca-key.pem"     = tls_private_key.intermediate[name].private_key_pem
      "root-cert.pem"  = tls_self_signed_cert.root.cert_pem
      "cert-chain.pem" = "${tls_locally_signed_cert.intermediate[name].cert_pem}${tls_self_signed_cert.root.cert_pem}"
    }
  }
}
