# vpc-peering

Same-account VPC peering with a route to the peer CIDR in every route table on both sides.

## Usage

```hcl
module "peering" {
  source = "../../modules/vpc-peering"

  name      = "outposts-to-localzone"
  requester = { vpc_id = module.a.vpc_id, cidr = module.a.vpc_cidr, route_table_ids = module.a.route_table_ids }
  accepter  = { vpc_id = module.b.vpc_id, cidr = module.b.vpc_cidr, route_table_ids = module.b.route_table_ids }
}
```

## Notes

- Forgetting the edge route tables is the most common cause of cross-cluster timeouts; this module routes all of them.
- Overlapping CIDRs are rejected at plan time.

## Inputs and outputs

See [variables.tf](variables.tf) and [outputs.tf](outputs.tf). Tests are in [tests/](tests/) and run with `terraform test`.
