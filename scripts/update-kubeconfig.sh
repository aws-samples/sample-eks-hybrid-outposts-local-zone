#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Adds both clusters to ~/.kube/config with the context names eks-outposts and eks-localzone.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require "$TF" aws jq

clusters=$(tf_output_json 20-clusters clusters)
region=$(jq -r .region <<<"$clusters")

for key in outposts localzone; do
  name=$(jq -r ".${key}.name" <<<"$clusters")
  aws eks update-kubeconfig --region "$region" --name "$name" --alias "$name" >/dev/null
  ok "context $name"
done
