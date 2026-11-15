# istio-remote-secret

Terraform equivalent of `istioctl create-remote-secret`: reads a token for `istio-reader-service-account` in the source cluster and writes an `istio/multiCluster` secret into the target cluster.

## Usage

```hcl
module "remote_secret_lz_in_outposts" {
  source    = "../../modules/istio-remote-secret"
  providers = { kubernetes.source = kubernetes.localzone, kubernetes.target = kubernetes.outposts }

  source_cluster_name = "cluster-lz"
  source_api_endpoint = module.eks_lz.endpoint
  source_ca_data      = module.eks_lz.certificate_authority_data
}
```

## Notes

- The module declares provider aliases, so `terraform validate` cannot run on it standalone; `terraform test` covers it.
- The target istiod must be able to reach `source_api_endpoint` (see the NAT IP allow list in `stacks/20-clusters`).
- The token can read every Secret in the source cluster (the istiod chart's `istio-reader` ClusterRole), so it is rotated: every `token_rotation_days` (default 30) the next apply creates a new `istio-reader-token-<suffix>` Secret, updates the remote secret, then deletes the old Secret, which revokes the old token. See [docs/security.md](../../docs/security.md#remote-secrets-and-the-reader-token).
- Uses the `hashicorp/time` provider for the rotation schedule.

## Inputs and outputs

See [variables.tf](variables.tf) and [outputs.tf](outputs.tf). Tests are in [tests/](tests/) and run with `terraform test`.
