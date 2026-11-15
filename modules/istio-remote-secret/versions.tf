# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    kubernetes = {
      source                = "hashicorp/kubernetes"
      version               = ">= 3.0, < 4.0"
      configuration_aliases = [kubernetes.source, kubernetes.target]
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.13, < 1.0"
    }
  }
}
