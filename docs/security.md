# Security

This sample is built to be deployed in a lab or a proof of concept. The defaults are hardened, and the list at the
end says what to change before you run production traffic on it.

## Controls in place

| Area | Control | Where |
|---|---|---|
| Network | No subnet assigns public IPs; nodes egress through NAT | `modules/edge-vpc` |
| Network | Default security group of each VPC has no rules | `modules/edge-vpc` |
| Network | Only TCP 15443 and ICMP from the peer VPC reach the nodes from outside the cluster | `modules/eks-edge-cluster` |
| Network | VPC Flow Logs for all traffic, KMS-encrypted, 365-day retention | `stacks/10-network` |
| EKS | Kubernetes secrets envelope-encrypted with a rotating KMS key | `modules/eks-edge-cluster` |
| EKS | All five control plane log types, KMS-encrypted, 365-day retention | `modules/eks-edge-cluster` |
| KMS | Key policies list explicit actions. Only `kms_admin_principal_arns` (default: the role running Terraform) can manage a key, through an `aws:PrincipalArn` condition on the account root, so recreating a deleted admin role by name restores access. No IAM principal can encrypt or decrypt directly. Deleted keys wait 30 days (`kms_deletion_window_days`) so a deletion can be cancelled. | `stacks/10-network`, `modules/eks-edge-cluster` |
| EKS | Public endpoint limited to admin CIDRs and the two NAT IPs; `0.0.0.0/0` rejected unless the lab-only `allow_public_api_from_anywhere` is set; admin CIDRs must be public and `/16` or narrower, with a plan warning above `/24` (see [EKS API endpoint access](#eks-api-endpoint-access)) | `stacks/20-clusters` |
| EKS | Access entries (API mode); no `aws-auth` ConfigMap. Optional named admins (`cluster_admin_principal_arns`) and `bootstrap_cluster_creator_admin_permissions = false` separate deployment from administration | `modules/eks-edge-cluster`, `stacks/20-clusters` |
| Nodes | IMDSv2 required, hop limit 1 | `modules/eks-edge-cluster` |
| Nodes | Encrypted root volumes; SSM Session Manager instead of SSH keys | `modules/eks-edge-cluster` |
| Mesh | Mesh-wide STRICT mTLS (verified by `make e2e`) | `modules/istio-primary` |
| Mesh | Gateway runs as non-root, drops all capabilities, read-only root filesystem | gateway chart |
| Mesh | Remote secrets use the read-only `istio-reader-service-account`; its token is rotated every 30 days and the old token revoked | `modules/istio-remote-secret` |
| Mesh | CloudWatch alarm when a cluster's reader token is used from any IP other than the peer NAT gateway | `modules/eks-edge-cluster`, `stacks/20-clusters` |
| Supply chain | Provider versions pinned and locked for Linux and macOS; GitHub Actions pinned to commit SHAs; Dependabot | repo |

## EKS API endpoint access

Each cluster's API server has a private endpoint (always on) and a public endpoint. The public endpoint exists
because the peer istiod must watch this API, and the EKS private endpoint name does not resolve across VPC peering.
The public endpoint still requires IAM authentication, so the allow list is defense in depth: it decides from where a
leaked kubeconfig, IAM credential, or remote-secret token can be used.

| Mode | Settings | Who can connect to port 443 | Use for |
|---|---|---|---|
| Private only | `endpoint_public_access = false` plus private connectivity between the VPCs (Production hardening, item 3) | Only networks routed to the VPCs | **Production (preferred)** |
| Allow list (default) | `admin_cidrs` plus the two NAT IPs, added automatically | Your admin networks and the peer istiod | **Production** if private-only is not possible yet; labs |
| Open | `allow_public_api_from_anywhere = true` in `20-clusters` | Any IP on the internet | **Labs only** where admin IPs change often |

For production environments, make the endpoints private, or keep an allow list that names only the networks that
administer the cluster:

- List specific `/32` addresses or small corporate or CI egress ranges in `admin_cidrs`. Avoid broad ranges; anything
  in them can reach the API. Plan rejects ranges wider than `/16` and private, CGNAT, loopback, or link-local ranges
  (the endpoint never sees those sources), and warns on anything wider than `/24`.
- Keep both NAT IPs on the list (the stack adds them). Removing them breaks cross-cluster endpoint discovery.
- Review the list when admins, VPNs, or CI runners change, and remove entries that are no longer used.
- Never set `allow_public_api_from_anywhere` in production.

With `allow_public_api_from_anywhere = true`, plan and apply print a warning from the `public_api_open_to_internet`
check. Set it back to `false` (and set `admin_cidrs`) when you are done, then run `make apply STACK=20-clusters`.

## Sensitive data in Terraform state

| Stack | Sensitive content |
|---|---|
| `30-mesh` | Root and intermediate CA private keys (when `create_cacerts = true`), reader service account tokens |
| `20-clusters` | Cluster CA certificates (not secret, but identifying) |

Use an S3 backend with KMS encryption, versioning, Block Public Access, and a bucket policy that limits reads to the
deployment role ([example](../examples/backend-s3.tf.example)).

## Remote secrets and the reader token

Each cluster holds a remote secret with a token for the other cluster's `istio-reader-service-account`. Read-only
does not mean low value: the istiod chart binds that account to a ClusterRole that can get, list, and watch **Secrets
in every namespace**, including `istio-system/cacerts`. Whoever holds the token can read every Secret in the peer
cluster, and an attacker who compromises `istio-system` in one cluster can read the other cluster's Secrets.

The role can't simply be narrowed. istiod opens a cluster-wide Secret watch in every remote cluster (its credentials
controller); without Secret access the remote cluster never finishes syncing, and istiod only proceeds after
`PILOT_REMOTE_CLUSTER_TIMEOUT`. Turning the watch off needs `PILOT_ENABLE_XDS_IDENTITY_CHECK=false`, which weakens
istiod. The token is treated as a high-value credential instead:

| Control | How |
|---|---|
| Rotation and revocation | Every `remote_secret_token_rotation_days` (default 30), the next `make apply STACK=30-mesh` creates a new token Secret, repoints the remote secret (istiod reloads it without a restart), then deletes the old token Secret, which revokes the old token. `terraform output remote_secret_tokens_rotate_at` shows the next rotation. Rotation needs an apply, so run the mesh stack at least that often. |
| Misuse alarm | `<cluster>-istio-reader-token-misuse` fires when the EKS audit log shows the token used from any IP other than the peer NAT gateway, for example from a copied state file. Set `reader_token_alarm.alarm_actions` in `20-clusters` to an SNS topic to be notified. Use from a compromised Pod in the peer cluster arrives through the expected NAT IP, so the alarm does not catch that case. |
| Network | The token works only from IPs on the EKS endpoint allow list (`admin_cidrs` and the two NAT IPs). |

To revoke a token immediately, delete the `istio-reader-token-*` Secret in the issuing cluster's `istio-system` and run
`make apply STACK=30-mesh`.

Limit what the token can reach: keep application credentials out of Kubernetes Secrets in mesh clusters, for
example with the AWS Secrets Manager and Config Provider for the Secrets Store CSI Driver without Secret sync, and
keep `istio-system` reserved for Istio. In this design both intermediates chain to one root, so a stolen `cacerts`
can mint identities the whole mesh trusts; issuing intermediates from AWS Private CA (Production hardening, item 1)
lets you revoke a compromised intermediate.

## Accepted scanner findings

Every exception has a written reason. Checkov exceptions are inline (`#checkov:skip=ID:reason`) next to the resource.
Trivy exceptions are in [`.trivyignore.yaml`](../.trivyignore.yaml).

| Finding | Why it is accepted |
|---|---|
| EKS public endpoint enabled (CKV_AWS_39, AWS-0040) | The peer istiod needs this API, and the private endpoint name does not resolve across peering. The endpoint is limited to listed CIDRs. |
| Node egress to `0.0.0.0/0` (CKV_AWS_382, AWS-0104) | Nodes need the EKS API, ECR, AWS service endpoints, and the peer network. Use VPC endpoints and an egress firewall to narrow this. |
| KMS key policy resource `*` (CKV_AWS_356) | In a key policy, `*` means this key only. |
| Kubernetes version list (CKV_AWS_339) | Checkov's list lags EKS releases; the default is checked against `aws eks describe-cluster-versions`. |
| AZ data source not pinned (CKV_AWS_394) | Only used to pick the second control plane AZ, which stays stable as AZs are added. |
| Validation manifests (namespace, image digest, pull policy, NetworkPolicy, Docker Hub) | Short-lived test workloads that `make e2e` deletes. |

## Production hardening

1. **CA.** Issue intermediates from AWS Private CA (for example with cert-manager and istio-csr) and set
   `create_cacerts = false`. Keep the root offline.
2. **Gateway IPs.** Run gateways on a dedicated node group with at least two nodes per location, and automate the
   meshNetworks refresh when a gateway node is replaced (for example, an EventBridge rule on Auto Scaling lifecycle
   events that runs the mesh stack).
3. **Private API access.** Replace the public endpoint path with private connectivity between VPCs (for example AWS
   Transit Gateway plus Route 53 Resolver rules for the EKS endpoint names), then set
   `endpoint_public_access = false`. Until then, keep the allow list tight and never set
   `allow_public_api_from_anywhere` (see [EKS API endpoint access](#eks-api-endpoint-access)).
   A private endpoint removes the internet-reachable path and significantly reduces the likelihood of a stolen token
   being used externally (T002) or of an istiod compromise being exploited across clusters (T017). It does not
   eliminate either risk: T002 residual is a thief already inside a peered VPC or admin network; T017 residual is
   any attacker who has already compromised `istio-system` in one cluster, regardless of network path.
4. **Egress.** Add VPC interface endpoints (ECR, STS, EC2, CloudWatch Logs, SSM) and AWS Network Firewall to remove
   the need for broad internet egress.
5. **VPC CNI permissions.** Move `AmazonEKS_CNI_Policy` from the node role to an IAM role for the `aws-node` service
   account (IRSA or EKS Pod Identity).
6. **Authorization.** Add Istio `AuthorizationPolicy` objects per namespace; STRICT mTLS proves identity but does not
   restrict who can call what.
7. **State access.** Separate the deployment role from read access to the `30-mesh` state.
8. **KMS key administrators.** Set `kms_admin_principal_arns` in `10-network` and `20-clusters` to the deployment role
   and a break-glass role. Keep `kms_deletion_window_days` at 30.
9. **Cluster administrators.** For new clusters, set `bootstrap_cluster_creator_admin_permissions = false` in
   `20-clusters` and list your admin, break-glass, and deployment roles in `cluster_admin_principal_arns`. Decide before
   the first apply: changing the bootstrap setting on existing clusters makes EKS replace them.
10. **Reader token alerts.** Point `reader_token_alarm.alarm_actions` at an SNS topic your on-call team watches, and
   keep application credentials out of Kubernetes Secrets in mesh clusters (see
   [Remote secrets and the reader token](#remote-secrets-and-the-reader-token)).
