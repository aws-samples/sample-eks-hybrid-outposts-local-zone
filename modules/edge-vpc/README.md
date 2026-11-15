# edge-vpc

VPC for one edge location: two regional subnets (EKS control plane ENIs and the NAT gateway) and one edge subnet on an AWS Outposts rack or in an AWS Local Zone.

## Usage

```hcl
module "vpc_outposts" {
  source = "../../modules/edge-vpc"

  name       = "edge-mesh-outposts"
  cidr_block = "10.0.0.0/16"
  regional_subnets = [
    { cidr = "10.0.1.0/24", availability_zone = "us-east-1a" },
    { cidr = "10.0.2.0/24", availability_zone = "us-east-1b" },
  ]
  edge_type              = "outposts"            # or "localzone"
  edge_subnet_cidr       = "10.0.10.0/24"
  edge_availability_zone = "us-east-1a"         # Outposts AZ, or the Local Zone name
  outpost_arn            = var.outpost_arn      # null for "localzone"
}
```

## Notes

- The edge subnet has no ELB discovery tags, because NLBs are not supported on Outposts subnets.
- No subnet assigns public IPs. The edge route table defaults to the NAT gateway.
- The default security group is emptied. Flow logs are on by default (pass `flow_logs.kms_key_arn` to encrypt them).
- `route_table_ids` has static keys (`regional`, `edge`) so `vpc-peering` can use it in `for_each`.

## Inputs and outputs

See [variables.tf](variables.tf) and [outputs.tf](outputs.tf). Tests are in [tests/](tests/) and run with `terraform test`.
