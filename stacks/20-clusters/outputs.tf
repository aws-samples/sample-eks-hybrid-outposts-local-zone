# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# scripts/export-outputs.sh writes this output into stacks/30-mesh/clusters.auto.tfvars.json.
output "clusters" {
  description = "Connection details for both clusters, keyed by location."
  value = {
    region = var.network.region

    outposts = {
      name                       = module.eks_outposts.cluster_name
      endpoint                   = module.eks_outposts.endpoint
      certificate_authority_data = module.eks_outposts.certificate_authority_data
      vpc_cidr                   = var.network.outposts.vpc_cidr
    }

    localzone = {
      name                       = module.eks_localzone.cluster_name
      endpoint                   = module.eks_localzone.endpoint
      certificate_authority_data = module.eks_localzone.certificate_authority_data
      vpc_cidr                   = var.network.localzone.vpc_cidr
    }
  }
}

output "update_kubeconfig_commands" {
  description = "Commands that add both clusters to your kubeconfig with stable context names."
  value = [
    "aws eks update-kubeconfig --region ${var.network.region} --name ${module.eks_outposts.cluster_name} --alias ${module.eks_outposts.cluster_name}",
    "aws eks update-kubeconfig --region ${var.network.region} --name ${module.eks_localzone.cluster_name} --alias ${module.eks_localzone.cluster_name}",
  ]
}
