#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers. Source this file; do not execute it.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

TF="${TERRAFORM:-terraform}"
# shellcheck disable=SC2034 # used by the scripts that source this file
STACKS=(10-network 20-clusters 30-mesh)

# Context names used by update-kubeconfig.sh and the validation scripts.
# shellcheck disable=SC2034
CTX_OUTPOSTS="${CTX_OUTPOSTS:-eks-outposts}"
CTX_LZ="${CTX_LZ:-eks-localzone}"

if [[ -t 1 ]]; then
  _B=$'\033[1m'; _G=$'\033[32m'; _Y=$'\033[33m'; _R=$'\033[31m'; _N=$'\033[0m'
else
  _B=""; _G=""; _Y=""; _R=""; _N=""
fi

log()  { printf '%s==>%s %s\n' "$_B" "$_N" "$*"; }
ok()   { printf '%s ok %s %s\n' "$_G" "$_N" "$*"; }
warn() { printf '%swarn%s %s\n' "$_Y" "$_N" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$_R" "$_N" "$*" >&2; exit 1; }

require() {
  local missing=()
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "missing tools: ${missing[*]} (see README prerequisites)"
}

stack_dir() { printf '%s/stacks/%s' "$REPO_ROOT" "$1"; }

tf_output_json() { "$TF" -chdir="$(stack_dir "$1")" output -json "$2"; }

confirm() {
  local prompt=$1 expected=$2 answer
  [[ "${AUTO_APPROVE:-0}" == "1" ]] && return 0
  read -r -p "$prompt " answer
  [[ "$answer" == "$expected" ]]
}
