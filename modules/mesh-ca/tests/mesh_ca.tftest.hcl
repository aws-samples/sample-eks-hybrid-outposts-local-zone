# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Uses the real tls provider: certificates are generated locally, nothing leaves the machine.

variables {
  mesh_id       = "edge-mesh"
  cluster_names = ["cluster-outposts", "cluster-lz"]
}

run "issues_one_intermediate_per_cluster" {
  command = apply

  assert {
    condition     = toset(keys(output.cacerts)) == toset(var.cluster_names)
    error_message = "Expected one cacerts bundle per cluster."
  }

  assert {
    condition = alltrue([
      for name, b in output.cacerts :
      toset(keys(b)) == toset(["ca-cert.pem", "ca-key.pem", "root-cert.pem", "cert-chain.pem"])
    ])
    error_message = "Each bundle must contain exactly the four keys Istio expects in the cacerts secret."
  }
}

run "every_cluster_shares_the_root" {
  command = apply

  assert {
    condition     = alltrue([for b in values(output.cacerts) : b["root-cert.pem"] == output.root_cert_pem])
    error_message = "All clusters must trust the same root."
  }

  assert {
    condition     = alltrue([for b in values(output.cacerts) : endswith(b["cert-chain.pem"], output.root_cert_pem) && startswith(b["cert-chain.pem"], b["ca-cert.pem"])])
    error_message = "cert-chain.pem must be the intermediate followed by the root."
  }

  assert {
    condition     = output.cacerts["cluster-outposts"]["ca-cert.pem"] != output.cacerts["cluster-lz"]["ca-cert.pem"]
    error_message = "Each cluster needs its own intermediate."
  }
}

run "intermediates_are_cas" {
  command = apply

  assert {
    condition     = alltrue([for c in tls_locally_signed_cert.intermediate : c.is_ca_certificate && contains(c.allowed_uses, "cert_signing")])
    error_message = "Intermediates must be CA certificates allowed to sign workload certificates."
  }
}

run "rejects_duplicate_cluster_names" {
  command = plan

  variables {
    cluster_names = ["cluster-a", "cluster-a"]
  }

  expect_failures = [var.cluster_names]
}

run "rejects_intermediate_outliving_root" {
  command = plan

  variables {
    root_validity_hours         = 8760
    intermediate_validity_hours = 17520
  }

  expect_failures = [var.intermediate_validity_hours]
}
