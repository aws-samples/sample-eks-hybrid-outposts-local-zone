#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end tests against the live mesh.
#
#  1. Control plane: istiod and the east-west gateway are healthy in both clusters.
#  2. Discovery: each cluster holds a remote secret for the other.
#  3. Data plane: from each cluster, repeated calls to helloworld return both
#     v1 (Outposts) and v2 (Local Zone).
#  4. Security: a client without a sidecar is refused (STRICT mTLS).
#
# Usage: validation/run-tests.sh [--keep]   (--keep leaves the sample workloads running)
# Env:   REQUESTS (default 20), CTX_OUTPOSTS, CTX_LZ

set -euo pipefail
# shellcheck source=../scripts/lib/common.sh
source "$(dirname "$0")/../scripts/lib/common.sh"

require kubectl

REQUESTS="${REQUESTS:-20}"
NS=sample
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1
MANIFESTS="$REPO_ROOT/validation/manifests"
PASS=0
FAIL=0

pass() { ok "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

cleanup() {
  if [[ $KEEP -eq 0 ]]; then
    log "Cleaning up namespace $NS"
    for ctx in "$CTX_OUTPOSTS" "$CTX_LZ"; do
      kubectl --context "$ctx" delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
      kubectl --context "$ctx" delete namespace "${NS}-nomesh" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
log "1. Control plane"
for ctx in "$CTX_OUTPOSTS" "$CTX_LZ"; do
  if kubectl --context "$ctx" -n istio-system rollout status deploy/istiod --timeout=120s >/dev/null; then
    pass "$ctx istiod available"
  else
    fail "$ctx istiod not available"
  fi
  if kubectl --context "$ctx" -n istio-system rollout status ds/istio-eastwestgateway --timeout=120s >/dev/null; then
    pass "$ctx east-west gateway ready"
  else
    fail "$ctx east-west gateway not ready"
  fi
  hostport=$(kubectl --context "$ctx" -n istio-system get ds istio-eastwestgateway \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="istio-proxy")].ports[?(@.name=="tls")].hostPort}')
  if [[ "$hostport" == "15443" ]]; then
    pass "$ctx gateway publishes 15443 on the node IP"
  else
    fail "$ctx gateway does not publish hostPort 15443 (got '${hostport}')"
  fi
  # Istio skips injection for hostNetwork Pods; an un-injected Pod keeps the "auto" image.
  images=$(kubectl --context "$ctx" -n istio-system get pods -l app=istio-eastwestgateway \
    -o jsonpath='{.items[*].spec.containers[*].image}')
  if [[ -n "$images" && " $images " != *" auto "* ]]; then
    pass "$ctx gateway proxy was injected"
  else
    fail "$ctx gateway proxy was not injected (images: '${images}')"
  fi
done

# ---------------------------------------------------------------------------
log "2. Cross-cluster discovery"
check_remote_secret() {
  local ctx=$1 peer=$2
  if kubectl --context "$ctx" -n istio-system get secret "istio-remote-secret-$peer" -o jsonpath='{.metadata.labels.istio/multiCluster}' 2>/dev/null | grep -q true; then
    pass "$ctx has remote secret for $peer"
  else
    fail "$ctx is missing istio-remote-secret-$peer"
  fi
}
check_remote_secret "$CTX_OUTPOSTS" cluster-lz
check_remote_secret "$CTX_LZ" cluster-outposts

if command -v istioctl >/dev/null 2>&1; then
  for ctx in "$CTX_OUTPOSTS" "$CTX_LZ"; do
    if istioctl --context "$ctx" remote-clusters 2>/dev/null | grep -q synced; then
      pass "$ctx istioctl remote-clusters reports synced"
    else
      fail "$ctx remote cluster not synced (istioctl remote-clusters)"
    fi
  done
fi

# ---------------------------------------------------------------------------
log "3. Data plane: deploying helloworld v1 (Outposts) and v2 (Local Zone)"
deploy_sample() {
  local ctx=$1 version=$2
  kubectl --context "$ctx" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null
  kubectl --context "$ctx" label namespace "$NS" istio-injection=enabled --overwrite >/dev/null
  kubectl --context "$ctx" -n "$NS" apply -f "$MANIFESTS/helloworld.yaml" -f "$MANIFESTS/sleep.yaml" >/dev/null
  sed "s/\${VERSION}/${version}/g" "$MANIFESTS/helloworld-deployment.yaml.tpl" \
    | kubectl --context "$ctx" -n "$NS" apply -f - >/dev/null
}
deploy_sample "$CTX_OUTPOSTS" v1
deploy_sample "$CTX_LZ" v2

for ctx in "$CTX_OUTPOSTS" "$CTX_LZ"; do
  kubectl --context "$ctx" -n "$NS" wait --for=condition=Available deploy --all --timeout=300s >/dev/null \
    || die "sample workloads did not become ready in $ctx"
done
sleep 10 # let endpoints propagate through both istiods

probe() {
  local ctx=$1 out v1=0 v2=0 errors=0 total=0
  for _ in $(seq 1 "$REQUESTS"); do
    if out=$(kubectl --context "$ctx" -n "$NS" exec deploy/sleep -c sleep -- \
      curl -sS --max-time 5 -w ' time_total=%{time_total}\n' helloworld."$NS":5000/hello 2>/dev/null); then
      [[ "$out" == *"version: v1"* ]] && v1=$((v1 + 1))
      [[ "$out" == *"version: v2"* ]] && v2=$((v2 + 1))
      total=$(awk -v a="$total" -v b="${out##*time_total=}" 'BEGIN{print a + b}')
    else
      errors=$((errors + 1))
    fi
  done
  local avg
  avg=$(awk -v t="$total" -v n="$((v1 + v2))" 'BEGIN{ if (n > 0) printf "%.3f", t / n; else print "n/a" }')
  printf '    %s: v1=%d v2=%d errors=%d avg=%ss\n' "$ctx" "$v1" "$v2" "$errors" "$avg"
  if [[ $v1 -gt 0 && $v2 -gt 0 && $errors -eq 0 ]]; then
    pass "$ctx reaches both the Outposts (v1) and Local Zone (v2) endpoints"
  else
    fail "$ctx did not reach both versions (see docs/troubleshooting.md)"
  fi
}
probe "$CTX_OUTPOSTS"
probe "$CTX_LZ"

# ---------------------------------------------------------------------------
log "4. Security: plaintext client outside the mesh must be refused"
kubectl --context "$CTX_OUTPOSTS" create namespace "${NS}-nomesh" --dry-run=client -o yaml \
  | kubectl --context "$CTX_OUTPOSTS" apply -f - >/dev/null
kubectl --context "$CTX_OUTPOSTS" -n "${NS}-nomesh" apply -f "$MANIFESTS/sleep.yaml" >/dev/null
kubectl --context "$CTX_OUTPOSTS" -n "${NS}-nomesh" wait --for=condition=Available deploy/sleep --timeout=180s >/dev/null
if kubectl --context "$CTX_OUTPOSTS" -n "${NS}-nomesh" exec deploy/sleep -- \
  curl -sS --max-time 5 "helloworld.${NS}:5000/hello" >/dev/null 2>&1; then
  fail "a client without a sidecar reached helloworld; STRICT mTLS is not enforced"
else
  pass "plaintext request refused (STRICT mTLS)"
fi

echo
log "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
