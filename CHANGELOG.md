# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Network stack: one VPC per edge location (Outposts, Local Zone), VPC peering, NAT gateways, KMS-encrypted VPC Flow Logs, Local Zone opt-in.
- Clusters stack: one Amazon EKS cluster per location with self-managed Amazon Linux 2023 nodes on the edge subnet, KMS secrets encryption, control plane logging, IMDSv2, and EKS access entries.
- Mesh stack: Istio multi-primary, multi-network install with Helm, shared root CA, east-west gateway (DaemonSet, hostPort 15443), meshNetworks from node IPs, remote secrets in both directions, STRICT mTLS.
- Offline tests: `terraform test` for every module and stack with mocked providers, and Helm chart tests.
- End-to-end validation script for live clusters.
- CI (fmt, validate, test, TFLint, chart tests, ShellCheck) and security workflows (Checkov, Trivy, secret scanning) with SARIF upload.
- Remote-secret reader tokens rotate every `remote_secret_token_rotation_days` (default 30, `30-mesh`): the next apply creates a new token Secret, repoints the remote secret, and deletes (revokes) the old token. New output `remote_secret_tokens_rotate_at`. Adds the `hashicorp/time` provider.
- CloudWatch metric filter and alarm `<cluster>-istio-reader-token-misuse` on each cluster's EKS audit log when its reader token is used from an IP other than the peer NAT gateway (`reader_token_alarm` in `20-clusters` and `modules/eks-edge-cluster`; on by default).
- `allow_public_api_from_anywhere` in `20-clusters` (default `false`, lab only) opens both EKS public endpoints to `0.0.0.0/0` and makes `admin_cidrs` optional; a `check` warns on every plan while it is on. `modules/eks-edge-cluster` gains the matching `allow_public_access_anywhere`. `docs/security.md` documents private, allow-list, and open endpoint modes and the production guidance.

### Changed

- `admin_cidrs` (`20-clusters`) must be public and `/16` or narrower; private, CGNAT, loopback, and link-local ranges are rejected, and a check warns above `/24`. `modules/eks-edge-cluster` also rejects `endpoint_public_access_cidrs` wider than `/16` (except the lab-only `0.0.0.0/0` opt-in).
- KMS keys (cluster and flow logs) now wait 30 days before deletion instead of 7 (`kms_deletion_window_days`, 7-30).
- New `bootstrap_cluster_creator_admin_permissions` (default `true`) and `cluster_admin_principal_arns` in `20-clusters` and `modules/eks-edge-cluster` to name cluster admins with `AmazonEKSClusterAdminPolicy` access entries. Changing the bootstrap setting on existing clusters replaces them.
- The remote-secret token Secret in each source cluster is renamed from `istio-reader-service-account-token` to `istio-reader-token-<suffix>`. The first apply after upgrading replaces it, which revokes the old token.
- License changed back to MIT-0: removed `NOTICE`, restored `LICENSE`, and `SPDX-License-Identifier: MIT-0` in every file header.
- KMS key policies (EKS secrets/control plane logs, VPC Flow Logs) list explicit actions instead of wildcards. The account statement covers key management only, with no Encrypt/Decrypt, and keeps `kms:PutKeyPolicy` so the key can't be locked out.
- KMS key administration is limited to `kms_admin_principal_arns` (new in `10-network`, `20-clusters`, and `modules/eks-edge-cluster`; default: the role running Terraform) through an `aws:PrincipalArn` condition on the account root. Every role that runs plan, apply, or destroy must be listed.
- `make validate`, `make test-unit`, `make init`, and `make lock` now fail when any module or stack fails, not only the last one.
- Dependabot waits 7 days before proposing new GitHub Actions and Terraform provider releases.
