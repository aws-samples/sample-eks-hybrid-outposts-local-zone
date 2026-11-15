#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Hands one stack's output to the next stack as an *.auto.tfvars.json file.
# This keeps the stacks independent of the state backend you choose.
#
# Usage: scripts/export-outputs.sh 10-network   -> stacks/20-clusters/network.auto.tfvars.json
#        scripts/export-outputs.sh 20-clusters  -> stacks/30-mesh/clusters.auto.tfvars.json

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require "$TF" jq

case "${1:-}" in
  10-network)  output=network;  target=20-clusters ;;
  20-clusters) output=clusters; target=30-mesh ;;
  *) die "usage: $0 10-network|20-clusters" ;;
esac

dest="$(stack_dir "$target")/${output}.auto.tfvars.json"
tf_output_json "$1" "$output" | jq --arg k "$output" '{($k): .}' >"$dest"
ok "exported $1.$output -> ${dest#"$REPO_ROOT"/}"
