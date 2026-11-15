# mesh-ca

Shared root CA and one intermediate CA per Istio cluster, in the format of Istio's `cacerts` secret. Lab use: the private keys are stored in Terraform state.

## Usage

```hcl
module "mesh_ca" {
  source = "../../modules/mesh-ca"

  mesh_id       = "edge-mesh"
  cluster_names = ["cluster-outposts", "cluster-lz"]
}

# module.mesh_ca.cacerts["cluster-outposts"] => { ca-cert.pem, ca-key.pem, root-cert.pem, cert-chain.pem }
```

## Notes

- For production, issue intermediates from AWS Private CA instead and pass `cacerts = null` to `istio-primary`.

## Inputs and outputs

See [variables.tf](variables.tf) and [outputs.tf](outputs.tf). Tests are in [tests/](tests/) and run with `terraform test`.
