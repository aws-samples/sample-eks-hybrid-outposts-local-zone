# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Lab-grade shared trust: one root CA and one intermediate CA per cluster,
# equivalent to Istio's tools/certs/Makefile.selfsigned.mk.
#
# WARNING: the private keys are stored in Terraform state. Use an encrypted,
# access-controlled backend, and for production issue the intermediates from
# AWS Private CA (for example with cert-manager and istio-csr) instead.

resource "tls_private_key" "root" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "root" {
  private_key_pem       = tls_private_key.root.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = var.root_validity_hours

  subject {
    organization = var.organization
    common_name  = "${var.mesh_id} Root CA"
  }

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
    "key_encipherment",
  ]
}

resource "tls_private_key" "intermediate" {
  for_each = toset(var.cluster_names)

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "intermediate" {
  for_each = toset(var.cluster_names)

  private_key_pem = tls_private_key.intermediate[each.key].private_key_pem
  dns_names       = ["istiod.istio-system.svc"]

  subject {
    organization = var.organization
    common_name  = "Intermediate CA"
    locality     = each.key
  }
}

resource "tls_locally_signed_cert" "intermediate" {
  for_each = toset(var.cluster_names)

  cert_request_pem      = tls_cert_request.intermediate[each.key].cert_request_pem
  ca_private_key_pem    = tls_private_key.root.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.root.cert_pem
  is_ca_certificate     = true
  validity_period_hours = var.intermediate_validity_hours

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
    "key_encipherment",
  ]
}
