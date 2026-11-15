# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# One Kubernetes and one Helm provider per cluster. Tokens come from
# "aws eks get-token", so whoever runs Terraform needs an EKS access entry
# (the cluster creator gets one automatically).

provider "kubernetes" {
  alias                  = "outposts"
  host                   = var.clusters.outposts.endpoint
  cluster_ca_certificate = base64decode(var.clusters.outposts.certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.clusters.outposts.name, "--region", var.clusters.region]
  }
}

provider "kubernetes" {
  alias                  = "localzone"
  host                   = var.clusters.localzone.endpoint
  cluster_ca_certificate = base64decode(var.clusters.localzone.certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.clusters.localzone.name, "--region", var.clusters.region]
  }
}

provider "helm" {
  alias = "outposts"

  kubernetes = {
    host                   = var.clusters.outposts.endpoint
    cluster_ca_certificate = base64decode(var.clusters.outposts.certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.clusters.outposts.name, "--region", var.clusters.region]
    }
  }
}

provider "helm" {
  alias = "localzone"

  kubernetes = {
    host                   = var.clusters.localzone.endpoint
    cluster_ca_certificate = base64decode(var.clusters.localzone.certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.clusters.localzone.name, "--region", var.clusters.region]
    }
  }
}
