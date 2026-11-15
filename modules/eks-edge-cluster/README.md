# eks-edge-cluster

Amazon EKS cluster whose control plane runs in the Region and whose self-managed Amazon Linux 2023 nodes run on an Outposts or Local Zone subnet.

## Usage

```hcl
module "eks_outposts" {
  source = "../../modules/eks-edge-cluster"

  name                         = "eks-outposts"
  kubernetes_version           = "1.37"
  location                     = "outposts"          # or "localzone" with local_zone_name
  outpost_arn                  = var.outpost_arn
  vpc_id                       = module.vpc.vpc_id
  control_plane_subnet_ids     = module.vpc.regional_subnet_ids
  edge_subnet_id               = module.vpc.edge_subnet_id
  peer_cidrs                   = ["10.1.0.0/16"]
  endpoint_public_access_cidrs = ["203.0.113.10/32"]
  instance_type                = "m7i.large"
  root_volume                  = { type = "gp3" }
}
```

## Notes

- Plan fails if the instance type is not installed on the Outposts or offered in the Local Zone.
- Nodes join through nodeadm and an `EC2_LINUX` access entry, and are labelled `edge-mesh.io/gateway=true`.
- Nodes are members of the EKS cluster security group (control plane traffic, including the Istio webhook) and of a node group that only admits TCP 15443 and ICMP from `peer_cidrs`.
- KMS envelope encryption for secrets, all control plane logs, IMDSv2 with hop limit 1, encrypted root volumes.
- Optional `reader_token_alarm`: a metric filter on the audit log and an alarm when the `istio-reader-service-account` token is used from any IP not in `allowed_source_ips` (the peer NAT IPs).

## Inputs and outputs

See [variables.tf](variables.tf) and [outputs.tf](outputs.tf). Tests are in [tests/](tests/) and run with `terraform test`.
