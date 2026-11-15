#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Offline tests for the hostPort east-west gateway chart. Needs helm only.

set -euo pipefail

CHART="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../modules/istio-primary/charts/eastwest-gateway" && pwd)"
PASS=0
FAIL=0

check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf '  ok   %s\n' "$name"; PASS=$((PASS + 1))
  else
    printf '  FAIL %s\n' "$name"; FAIL=$((FAIL + 1))
  fi
}

# refute NAME PATTERN TEXT: passes when PATTERN does not occur in TEXT.
refute() {
  local name=$1 pattern=$2 text=$3
  if grep -q -- "$pattern" <<<"$text"; then
    printf '  FAIL %s\n' "$name"; FAIL=$((FAIL + 1))
  else
    printf '  ok   %s\n' "$name"; PASS=$((PASS + 1))
  fi
}

# tls_port_on_node TEXT: passes when containerPort 15443 is followed by hostPort 15443.
tls_port_on_node() {
  awk '/containerPort: 15443/ { getline; if ($0 ~ /hostPort: 15443/) found = 1 } END { exit !found }' <<<"$1"
}

render() { helm template istio-eastwestgateway "$CHART" --namespace istio-system "$@"; }

echo "helm lint"
helm lint "$CHART" --set network=network-test >/dev/null

echo "rendering with defaults"
OUT=$(render --set network=network-test)

check "DaemonSet, one gateway per node"          grep -q 'kind: DaemonSet' <<<"$OUT"
refute "no host networking (injector skips it)"   'hostNetwork' "$OUT"
check "TLS port published on the node IP"        tls_port_on_node "$OUT"
check "only the TLS port is published"           test "$(grep -c 'hostPort:' <<<"$OUT")" -eq 1
refute "no net.* sysctls in the chart"            'sysctls' "$OUT"
check "gateway injection template requested"     grep -q 'inject.istio.io/templates: gateway' <<<"$OUT"
check "pods labelled with their network"         grep -q 'topology.istio.io/network: "network-test"' <<<"$OUT"
check "requested network view set"               grep -A1 'ISTIO_META_REQUESTED_NETWORK_VIEW' <<<"$OUT"
check "Service is ClusterIP (no load balancer)"  grep -q 'type: ClusterIP' <<<"$OUT"
refute "no LoadBalancer Service anywhere"        'type: LoadBalancer' "$OUT"
check "cross-network Gateway is AUTO_PASSTHROUGH" grep -q 'mode: AUTO_PASSTHROUGH' <<<"$OUT"
check "Gateway exposes TLS on 15443"             grep -q 'number: 15443' <<<"$OUT"
check "STRICT mTLS by default"                   grep -q 'mode: STRICT' <<<"$OUT"
check "container drops all capabilities"         grep -A1 'drop:' <<<"$OUT"
check "container runs as non-root"               grep -q 'runAsNonRoot: true' <<<"$OUT"
check "gateway scheduled on gateway nodes"       grep -q 'edge-mesh.io/gateway: "true"' <<<"$OUT"

echo "rendering with enforceStrictMtls=false"
OUT=$(render --set network=network-test --set enforceStrictMtls=false)
refute "PeerAuthentication omitted when disabled" 'kind: PeerAuthentication' "$OUT"

echo "rendering without a network"
if helm template x "$CHART" >/dev/null 2>&1; then
  printf '  FAIL %s\n' "chart refuses to render without network"; FAIL=$((FAIL + 1))
else
  printf '  ok   %s\n' "chart refuses to render without network"; PASS=$((PASS + 1))
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
