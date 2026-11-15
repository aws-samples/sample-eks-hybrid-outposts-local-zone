# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# scripts/export-outputs.sh writes this output into stacks/20-clusters/network.auto.tfvars.json.
output "network" {
  description = "Everything the clusters stack needs from the network stack."
  value = {
    region = var.region

    outposts = {
      vpc_id              = module.vpc_outposts.vpc_id
      vpc_cidr            = module.vpc_outposts.vpc_cidr
      regional_subnet_ids = module.vpc_outposts.regional_subnet_ids
      edge_subnet_id      = module.vpc_outposts.edge_subnet_id
      nat_public_ip       = module.vpc_outposts.nat_public_ip
      outpost_arn         = var.outpost_arn
      availability_zone   = local.outposts_az
    }

    localzone = {
      vpc_id              = module.vpc_localzone.vpc_id
      vpc_cidr            = module.vpc_localzone.vpc_cidr
      regional_subnet_ids = module.vpc_localzone.regional_subnet_ids
      edge_subnet_id      = module.vpc_localzone.edge_subnet_id
      nat_public_ip       = module.vpc_localzone.nat_public_ip
      local_zone_name     = var.local_zone_name
      parent_zone         = local.local_zone_parent
    }

    peering_connection_id = module.peering.id
  }
}
