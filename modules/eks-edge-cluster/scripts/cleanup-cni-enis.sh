#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Destroy-time cleanup for ENIs the Amazon VPC CNI leaves behind.
#
# When the node Auto Scaling group is deleted, the VPC CNI can leave its
# secondary ENIs in the "available" state (seen on Outposts subnets). They still
# carry the node security group, so deleting that group fails with
# DependencyViolation. Terraform runs this after the Auto Scaling group is gone
# and before the security group is deleted.
#
# Only ENIs that match all of the following are deleted:
#   - in the given VPC
#   - status "available" (not attached to anything)
#   - tag eks:eni:owner = amazon-vpc-cni
#   - tag cluster.k8s.amazonaws.com/name = the given cluster
#
# The script then waits until no ENI uses the node security group, so ENIs still
# detaching from terminating instances are picked up on a later pass.
#
# Usage: cleanup-cni-enis.sh REGION CLUSTER_NAME VPC_ID SECURITY_GROUP_ID
# Env:   ENI_CLEANUP_TIMEOUT (seconds, default 900), ENI_CLEANUP_INTERVAL (default 15)

set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 REGION CLUSTER_NAME VPC_ID SECURITY_GROUP_ID" >&2
  exit 2
fi

region=$1 cluster=$2 vpc_id=$3 sg_id=$4
timeout=${ENI_CLEANUP_TIMEOUT:-900}
interval=${ENI_CLEANUP_INTERVAL:-15}
deadline=$(( $(date +%s) + timeout ))

log() { printf '[eni-cleanup %s] %s\n' "$cluster" "$*" >&2; }

command -v aws >/dev/null 2>&1 || { log "aws CLI not found"; exit 1; }

orphaned_cni_enis() {
  aws ec2 describe-network-interfaces --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" \
              "Name=status,Values=available" \
              "Name=tag:eks:eni:owner,Values=amazon-vpc-cni" \
              "Name=tag:cluster.k8s.amazonaws.com/name,Values=$cluster" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
}

enis_using_sg() {
  aws ec2 describe-network-interfaces --region "$region" \
    --filters "Name=group-id,Values=$sg_id" \
    --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,Description]' --output text
}

while true; do
  if ! orphans=$(orphaned_cni_enis); then
    log "could not list ENIs (aws error above); retrying"
    orphans=""
  fi
  for eni in $orphans; do
    log "deleting orphaned VPC CNI ENI $eni"
    # Another pass (or EC2 itself) may have removed it already.
    aws ec2 delete-network-interface --region "$region" --network-interface-id "$eni" 2>&1 \
      | grep -v 'InvalidNetworkInterfaceID.NotFound' >&2 || true
  done

  remaining=$(enis_using_sg)
  if [[ -z "$remaining" ]]; then
    log "no ENIs use $sg_id; security group can be deleted"
    exit 0
  fi

  if (( $(date +%s) >= deadline )); then
    log "timed out after ${timeout}s; ENIs still using $sg_id:"
    printf '%s\n' "$remaining" >&2
    log "only unattached VPC CNI ENIs of $cluster are deleted; anything above is still attached or owned by something else"
    exit 1
  fi

  log "waiting for ENIs to detach from $sg_id: $(awk '{print $1 "(" $2 ")"}' <<<"$remaining" | tr '\n' ' ')"
  sleep "$interval"
done
