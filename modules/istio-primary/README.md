# istio-primary

Istio primary for one cluster of a multi-network mesh: `base` and `istiod` charts, plus the bundled `eastwest-gateway` chart (DaemonSet with hostPort 15443, cross-network Gateway, optional STRICT PeerAuthentication).

## Usage

```hcl
module "istio_outposts" {
  source    = "../../modules/istio-primary"
  providers = { kubernetes = kubernetes.outposts, helm = helm.outposts }

  istio_version = "1.30.8"
  mesh_id       = "edge-mesh"
  cluster_name  = "cluster-outposts"
  network       = "network-outposts"
  mesh_networks = {
    network-outposts = { registry = "cluster-outposts", gateways = ["10.0.10.5"] }
    network-lz      = { registry = "cluster-lz",      gateways = ["10.1.10.5"] }
  }
  cacerts = module.mesh_ca.cacerts["cluster-outposts"]
}
```

## Notes

- `meshNetworks` is passed as istiod chart values; no ConfigMap patching or istiod restart.
- The istiod `gateways.securityContext` override removes the `net.ipv4.ip_unprivileged_port_start` sysctl; the gateway only binds ports above 1024.
- The gateway never uses `hostNetwork`: Istio's injector skips host-network Pods.
- Chart tests: `tests/chart/test_eastwest_gateway.sh`.

## Inputs and outputs

See [variables.tf](variables.tf) and [outputs.tf](outputs.tf). Tests are in [tests/](tests/) and run with `terraform test`.
