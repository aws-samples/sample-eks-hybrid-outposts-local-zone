#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Read-only checks before deploying: tools, versions, AWS identity, Outposts.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

log "Checking tools"
require "$TF" aws kubectl jq helm

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

tf_version=$("$TF" version -json | jq -r .terraform_version)
version_ge "$tf_version" "1.10.0" || die "Terraform $tf_version found; 1.10.0 or later is required"
ok "terraform $tf_version"

aws_version=$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)
[[ "$aws_version" == 2.* ]] || die "AWS CLI v2 is required (found $aws_version)"
ok "aws-cli $aws_version"

ok "kubectl $(kubectl version --client -o json | jq -r .clientVersion.gitVersion)"
ok "helm $(helm version --short)"

if command -v istioctl >/dev/null 2>&1; then
  ok "istioctl $(istioctl version --remote=false 2>/dev/null | head -1) (optional)"
else
  warn "istioctl not found; it is optional and only used for troubleshooting"
fi

log "Checking AWS identity"
identity=$(aws sts get-caller-identity --output json) || die "no AWS credentials; configure a profile or SSO session"
ok "account $(jq -r .Account <<<"$identity") as $(jq -r .Arn <<<"$identity")"

region="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region || true)}}"
[[ -n "$region" ]] || die "set AWS_REGION to the Outposts parent Region"
ok "region $region"

log "Checking Outposts"
count=$(aws outposts list-outposts --region "$region" --query 'length(Outposts)' --output text)
[[ "$count" -gt 0 ]] || die "no Outposts found in $region"
aws outposts list-outposts --region "$region" \
  --query 'Outposts[].[OutpostId,AvailabilityZone,LifeCycleStatus,Name]' --output text \
  | while read -r id az status name; do ok "$id in $az ($status) $name"; done

log "Preflight passed"
