#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Destroys everything in reverse order: validation workloads, 30-mesh,
# 20-clusters, 10-network. Asks for confirmation unless AUTO_APPROVE=1.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require "$TF" kubectl

warn "This deletes both EKS clusters, both VPCs, the peering connection, NAT gateways, and KMS keys (7-day deletion window)."
confirm "Type 'destroy' to continue:" destroy || die "aborted"

log "Removing validation workloads (if any)"
for ctx in "$CTX_OUTPOSTS" "$CTX_LZ"; do
  kubectl --context "$ctx" delete namespace sample --ignore-not-found --wait=true --timeout=180s 2>/dev/null \
    || warn "could not reach $ctx; skipping"
done

for (( i=${#STACKS[@]}-1; i>=0; i-- )); do
  stack=${STACKS[$i]}
  dir=$(stack_dir "$stack")
  if [[ ! -f "$dir/terraform.tfstate" && ! -d "$dir/.terraform" ]]; then
    warn "$stack has no local state; skipping (remote backends are still destroyed if initialised)"
    continue
  fi
  log "Destroying $stack"
  "$TF" -chdir="$dir" init -input=false >/dev/null
  "$TF" -chdir="$dir" destroy -input=false -auto-approve
done

rm -f "$(stack_dir 20-clusters)/network.auto.tfvars.json" "$(stack_dir 30-mesh)/clusters.auto.tfvars.json"
ok "All stacks destroyed. The Local Zone opt-in and the Outposts capacity are left as they were."
