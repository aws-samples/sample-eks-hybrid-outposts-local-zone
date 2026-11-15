#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Applies the stacks in order: 10-network -> 20-clusters -> 30-mesh.
#
# Usage: scripts/deploy.sh [all|10-network|20-clusters|30-mesh]
#        AUTO_APPROVE=1 scripts/deploy.sh all     # non-interactive

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require "$TF" aws jq kubectl

apply_stack() {
  local stack=$1 dir
  dir=$(stack_dir "$stack")
  log "Applying $stack"
  "$TF" -chdir="$dir" init -input=false -upgrade=false >/dev/null
  if [[ "${AUTO_APPROVE:-0}" == "1" ]]; then
    "$TF" -chdir="$dir" apply -input=false -auto-approve
  else
    "$TF" -chdir="$dir" apply -input=false
  fi
}

after_stack() {
  case "$1" in
    10-network)
      "$REPO_ROOT/scripts/export-outputs.sh" 10-network ;;
    20-clusters)
      "$REPO_ROOT/scripts/export-outputs.sh" 20-clusters
      "$REPO_ROOT/scripts/update-kubeconfig.sh"
      "$REPO_ROOT/scripts/wait-for-nodes.sh" ;;
    30-mesh)
      "$TF" -chdir="$(stack_dir 30-mesh)" output mesh ;;
  esac
}

target="${1:-all}"
if [[ "$target" == "all" ]]; then
  for stack in "${STACKS[@]}"; do
    apply_stack "$stack"
    after_stack "$stack"
  done
  log "Done. Validate with: make e2e"
else
  [[ " ${STACKS[*]} " == *" $target "* ]] || die "unknown stack $target"
  apply_stack "$target"
  after_stack "$target"
fi
