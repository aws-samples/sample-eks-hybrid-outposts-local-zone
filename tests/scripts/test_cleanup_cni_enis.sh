#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Offline tests for modules/eks-edge-cluster/scripts/cleanup-cni-enis.sh.
# A stub "aws" on PATH serves ENIs from a state file, so no AWS access is needed.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../modules/eks-edge-cluster/scripts" && pwd)/cleanup-cni-enis.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0

ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Stub aws CLI. State lines: id|status|owner|cluster|vpc|sg
# A status of "detaching" turns into "available" after the first security-group query.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/aws" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
state="$STUB_STATE"
args="$*"
filter() { sed -n "s|.*Name=$1,Values=\([^ ]*\).*|\1|p" <<<"$args"; }
case "$args" in
  *delete-network-interface*)
    id=$(sed -n 's/.*--network-interface-id \([^ ]*\).*/\1/p' <<<"$args")
    echo "$id" >>"$STUB_DELETED"
    grep -v "^$id|" "$state" >"$state.tmp" || true; mv "$state.tmp" "$state" ;;
  *Name=group-id*)
    sg=$(filter group-id)
    awk -F'|' -v sg="$sg" '$6 == sg { print $1 "\t" $2 "\tdesc" }' "$state"
    sed -i.bak 's/|detaching|/|available|/' "$state" ;;
  *Name=status,Values=available*)
    awk -F'|' -v vpc="$(filter vpc-id)" -v owner="$(filter tag:eks:eni:owner)" \
        -v cl="$(filter tag:cluster.k8s.amazonaws.com/name)" \
      '$2 == "available" && $3 == owner && $4 == cl && $5 == vpc { printf "%s\t", $1 } END { print "" }' "$state" ;;
  *) echo "unexpected aws call: $args" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/aws"

run_case() {
  # run_case STATE_LINES... ; sets RC and leaves deletions in $WORK/deleted
  printf '%s\n' "$@" >"$WORK/state"
  : >"$WORK/deleted"
  RC=0
  PATH="$WORK/bin:$PATH" STUB_STATE="$WORK/state" STUB_DELETED="$WORK/deleted" \
    ENI_CLEANUP_INTERVAL=0 ENI_CLEANUP_TIMEOUT="${TIMEOUT:-5}" \
    bash "$SCRIPT" us-east-1 eks-outposts vpc-1 sg-nodes >/dev/null 2>"$WORK/stderr" || RC=$?
}

echo "orphaned CNI ENI on the node security group"
run_case "eni-orphan|available|amazon-vpc-cni|eks-outposts|vpc-1|sg-nodes" \
         "eni-other-cluster|available|amazon-vpc-cni|eks-localzone|vpc-1|sg-peer" \
         "eni-not-cni|available|someone-else|eks-outposts|vpc-1|sg-other"
[[ $RC -eq 0 ]] && ok "exits 0 once the security group is free" || bad "exit code $RC"
grep -qx eni-orphan "$WORK/deleted" && ok "deletes the orphaned CNI ENI" || bad "orphan not deleted"
grep -q -e eni-other-cluster -e eni-not-cni "$WORK/deleted" && bad "deleted an ENI it does not own" \
  || ok "leaves other clusters' and non-CNI ENIs alone"

echo "CNI ENI still detaching from a terminating node"
run_case "eni-late|detaching|amazon-vpc-cni|eks-outposts|vpc-1|sg-nodes"
[[ $RC -eq 0 ]] && ok "waits, then exits 0" || bad "exit code $RC"
grep -qx eni-late "$WORK/deleted" && ok "deletes it once it becomes available" || bad "late ENI not deleted"

echo "foreign ENI holding the security group"
TIMEOUT=0 run_case "eni-foreign|in-use|someone-else|eks-outposts|vpc-1|sg-nodes"
[[ $RC -ne 0 ]] && ok "fails after the timeout" || bad "should have failed"
[[ ! -s "$WORK/deleted" ]] && ok "does not delete it" || bad "deleted a foreign ENI"
grep -q eni-foreign "$WORK/stderr" && ok "names the blocking ENI" || bad "blocking ENI not reported"

echo "nothing to clean up"
run_case ""
[[ $RC -eq 0 && ! -s "$WORK/deleted" ]] && ok "exits 0 without deleting anything" || bad "exit $RC"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
