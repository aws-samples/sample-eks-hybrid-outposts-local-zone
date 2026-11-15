# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.4"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    # Used by modules/mesh-ca; pinned here so the stack's lock file controls it.
    # tflint-ignore: terraform_unused_required_providers
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
    # Used by modules/istio-remote-secret for token rotation.
    # tflint-ignore: terraform_unused_required_providers
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }

  # This stack's state contains the mesh CA private keys and service account
  # tokens. Use an encrypted, access-controlled backend (examples/backend-s3.tf.example).
}
