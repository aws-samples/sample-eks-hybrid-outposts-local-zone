#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Read-only discovery that writes starter terraform.tfvars files.
#
# Usage: AWS_REGION=us-east-1 LOCAL_ZONE=us-east-1-mia-2 scripts/discover.sh
# Existing terraform.tfvars files are never overwritten.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require aws jq curl

REGION="${AWS_REGION:?set AWS_REGION to the Outposts parent Region}"
LOCAL_ZONE="${LOCAL_ZONE:?set LOCAL_ZONE, for example us-east-1-mia-2}"

log "Outposts in $REGION"
outposts=$(aws outposts list-outposts --region "$REGION" --output json)
count=$(jq '.Outposts | length' <<<"$outposts")
[[ "$count" -gt 0 ]] || die "no Outposts found in $REGION"
if [[ -n "${OUTPOST_ID:-}" ]]; then
  outpost_arn=$(jq -r --arg id "$OUTPOST_ID" '.Outposts[] | select(.OutpostId == $id) | .OutpostArn' <<<"$outposts")
  [[ -n "$outpost_arn" ]] || die "Outposts $OUTPOST_ID not found"
else
  [[ "$count" -eq 1 ]] || die "found $count Outposts; set OUTPOST_ID to pick one"
  outpost_arn=$(jq -r '.Outposts[0].OutpostArn' <<<"$outposts")
fi
ok "$outpost_arn"

log "Instance types installed on the Outposts"
aws outposts get-outpost-instance-types --region "$REGION" --outpost-id "$outpost_arn" \
  --query 'InstanceTypes[].InstanceType' --output text | tr '\t' '\n' | sort -u | sed 's/^/    /'

log "Local Zone $LOCAL_ZONE"
lz=$(aws ec2 describe-availability-zones --region "$REGION" --all-availability-zones \
  --filters "Name=zone-name,Values=$LOCAL_ZONE" --query 'AvailabilityZones[0]' --output json)
[[ "$lz" != "null" ]] || die "Local Zone $LOCAL_ZONE not found in $REGION"
ok "group $(jq -r .GroupName <<<"$lz"), parent $(jq -r .ParentZoneName <<<"$lz"), opt-in $(jq -r .OptInStatus <<<"$lz")"

log "Instance types offered in $LOCAL_ZONE"
aws ec2 describe-instance-type-offerings --region "$REGION" --location-type availability-zone \
  --filters "Name=location,Values=$LOCAL_ZONE" \
  --query 'InstanceTypeOfferings[].InstanceType' --output text | tr '\t' '\n' | sort -u | sed 's/^/    /'

write_once() {
  local file=$1 content=$2
  if [[ -f "$file" ]]; then
    warn "$file exists, not overwritten"
  else
    printf '%s\n' "$content" >"$file"
    ok "wrote $file"
  fi
}

admin_ip=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')

write_once "$(stack_dir 10-network)/terraform.tfvars" "region          = \"$REGION\"
outpost_arn     = \"$outpost_arn\"
local_zone_name = \"$LOCAL_ZONE\""

write_once "$(stack_dir 20-clusters)/terraform.tfvars" "# Detected egress IP of this machine. Add CI runner CIDRs if needed.
admin_cidrs = [\"$admin_ip/32\"]"

log "Review the instance types above against stacks/20-clusters/variables.tf defaults before deploying"
