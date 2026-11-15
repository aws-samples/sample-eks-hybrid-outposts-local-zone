# Troubleshooting

Set the contexts once:

```bash
export CTX_A=eks-outposts CTX_B=eks-localzone
```

## Deployment

| Symptom | Likely cause | Check or fix |
|---|---|---|
| `Instance type ... is not available on this outposts` at plan | Type not installed on the rack | `aws outposts get-outpost-instance-types --outpost-id <arn>` and set `outposts_nodes.instance_type` |
| Same error for `localzone` | Type not offered in the Local Zone | `aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=location,Values=<lz>` |
| Local Zone subnet creation fails with `OptInRequired` | Zone group not opted in yet | Keep `manage_local_zone_opt_in = true`, or opt in from the EC2 console, then re-apply |
| Launch fails with an unsupported volume type | The Local Zone or Outposts does not offer that EBS type | Use `gp2` for `localzone_nodes.volume_type` |
| `wait-for-nodes.sh` times out | Node cannot join | EC2 console output of the instance; confirm the NAT route on the edge route table and the access entry for the node role |
| Mesh stack fails with `Every mesh network needs at least one gateway address` | Nodes not Ready, or missing the gateway label | `kubectl --context $CTX_A get nodes -L edge-mesh.io/gateway` |
| Mesh stack cannot reach the cluster (`Unauthorized` or timeout) | Your IP is not in `admin_cidrs`, or you are not the cluster creator | Add your CIDR and re-apply `20-clusters`; add an access entry for your role |
| `destroy` fails with `DependencyViolation` on `<cluster>-nodes-*` security group | An ENI still uses the group. The destroy-time cleanup already deleted unattached VPC CNI ENIs and waited 15 minutes, so what is left is attached or not owned by the VPC CNI (it is named in the `[eni-cleanup]` output) | `aws ec2 describe-network-interfaces --filters Name=group-id,Values=<sg-id>`; remove the owner, then re-run `make destroy`. Raise the wait with `ENI_CLEANUP_TIMEOUT=<seconds>` |
| `10-network` destroy fails with `DependencyViolation` on the VPC | A leftover `eks-cluster-sg-<cluster>-*` security group. EKS could not delete it because an orphaned VPC CNI ENI still used it when the cluster was deleted (the destroy-time cleanup now runs before the cluster is deleted) | `aws ec2 describe-security-groups --filters Name=vpc-id,Values=<vpc-id>`; delete the `eks-cluster-sg-*` group (and any ENI using it), then re-run `make destroy` |

## Mesh

**Gateway Pods stuck in `CreateContainerConfigError` or rejected.**

```bash
kubectl --context $CTX_A -n istio-system describe ds istio-eastwestgateway
```

If you see a sysctl error, the istiod `gateways.securityContext` override is missing. It is set in
`modules/istio-primary/main.tf`.

**Remote cluster not synced.**

```bash
istioctl --context $CTX_A remote-clusters
kubectl --context $CTX_A -n istio-system logs deploy/istiod | grep -i -E 'remote|kube.*config|cluster-lz'
```

Usually the peer's API endpoint is not reachable from this VPC. Confirm that both NAT IPs are in the peer endpoint's
public access CIDRs (`terraform -chdir=stacks/20-clusters output`).

**Requests only return the local version.**

1. Endpoints seen by the client sidecar. The remote endpoints must show the peer gateway IP on port 15443:

   ```bash
   istioctl --context $CTX_A proxy-config endpoints deploy/sleep.sample --cluster 'outbound|5000||helloworld.sample.svc.cluster.local'
   ```

2. meshNetworks as istiod sees it:

   ```bash
   kubectl --context $CTX_A -n istio-system get cm istio -o jsonpath='{.data.meshNetworks}'
   ```

3. Reachability of the peer gateway from a node in the other VPC (from an SSM session on an Outposts node):

   ```bash
   nc -vz <lz-gateway-node-ip> 15443
   ```

   A timeout here is a routing or security group problem: check the peering routes on the **edge** route tables, and
   the node security group rule for TCP 15443 from the peer CIDR.

4. Gateway logs in the destination cluster:

   ```bash
   kubectl --context $CTX_B -n istio-system logs ds/istio-eastwestgateway --tail=50
   ```

**A gateway node was replaced and cross-cluster calls stopped.** The meshNetworks entry still points at the old IP.
Re-run `make apply STACK=30-mesh`.

**Plaintext client is not refused in `make e2e`.** Check for a `PeerAuthentication` that overrides the mesh-wide
STRICT policy:

```bash
kubectl --context $CTX_A get peerauthentication -A
```

## Inspecting a live request

```bash
kubectl --context $CTX_A -n sample logs deploy/sleep -c istio-proxy --tail=10                 # client
kubectl --context $CTX_B -n istio-system logs ds/istio-eastwestgateway --tail=10              # gateway
kubectl --context $CTX_B -n sample logs deploy/helloworld-v2 -c istio-proxy --tail=10         # server
```
