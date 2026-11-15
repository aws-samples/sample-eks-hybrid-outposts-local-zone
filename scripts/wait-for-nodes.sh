#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Waits until each cluster has at least one Ready gateway node. The mesh stack
# reads those node IPs, so it must not run before this succeeds.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require kubectl

TIMEOUT="${TIMEOUT:-900}"
SELECTOR="edge-mesh.io/gateway=true"

for ctx in "$CTX_OUTPOSTS" "$CTX_LZ"; do
  log "Waiting up to ${TIMEOUT}s for a Ready gateway node in $ctx"
  deadline=$((SECONDS + TIMEOUT))
  until [[ $(kubectl --context "$ctx" get nodes -l "$SELECTOR" --no-headers 2>/dev/null | wc -l) -gt 0 ]]; do
    [[ $SECONDS -lt $deadline ]] || die "no node registered in $ctx; check the Auto Scaling group and the node's console output"
    sleep 15
  done
  remaining=$((deadline - SECONDS))
  kubectl --context "$ctx" wait node -l "$SELECTOR" --for=condition=Ready --timeout="${remaining}s" >/dev/null \
    || die "gateway nodes in $ctx did not become Ready"
  kubectl --context "$ctx" get nodes -l "$SELECTOR" \
    -o custom-columns='NODE:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address,ZONE:.metadata.labels.topology\.kubernetes\.io/zone' \
    | sed 's/^/    /'
  ok "$ctx ready"
done
