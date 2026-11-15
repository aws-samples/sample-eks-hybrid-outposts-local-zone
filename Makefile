# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

TERRAFORM  ?= terraform
TFLINT     ?= tflint
CHECKOV    ?= checkov
TRIVY      ?= trivy
SHELLCHECK ?= shellcheck
export TERRAFORM

MODULES := $(sort $(wildcard modules/*))
STACKS  := stacks/10-network stacks/20-clusters stacks/30-mesh
ROOTS   := $(MODULES) $(STACKS)
# Modules that declare configuration_aliases cannot be validated standalone;
# their behaviour is covered by terraform test instead.
VALIDATE_SKIP := modules/istio-remote-secret
SCRIPTS := $(wildcard scripts/*.sh) scripts/lib/common.sh validation/run-tests.sh $(wildcard tests/chart/*.sh) \
	$(wildcard tests/scripts/*.sh) $(wildcard modules/*/scripts/*.sh)
LOCK_PLATFORMS := -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_amd64 -platform=darwin_arm64

STACK ?=

##@ Help
.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n"} \
	  /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Quality (offline, no AWS credentials needed)
.PHONY: fmt fmt-check init validate lint test test-unit test-chart test-scripts shellcheck security checkov trivy secrets ci pre-commit
fmt: ## Format all Terraform files
	$(TERRAFORM) fmt -recursive .

fmt-check: ## Fail if any Terraform file is not formatted
	$(TERRAFORM) fmt -recursive -check -diff .

init: ## terraform init (no backend) in every module and stack
	@for d in $(ROOTS); do echo "init $$d"; $(TERRAFORM) -chdir=$$d init -backend=false -input=false -no-color >/dev/null || exit 1; done

# Loops below run every root, then fail if any root failed (a bare for loop only
# reports the last iteration's exit status).
validate: init ## terraform validate every module and stack
	@rc=0; for d in $(filter-out $(VALIDATE_SKIP),$(ROOTS)); do printf '%-32s ' "$$d"; \
	  if out=$$($(TERRAFORM) -chdir=$$d validate -no-color 2>&1); then echo "$$out" | head -1; else echo; echo "$$out"; rc=1; fi; \
	done; exit $$rc

lint: ## TFLint with the AWS ruleset
	$(TFLINT) --init --config "$(CURDIR)/.tflint.hcl"
	$(TFLINT) --recursive --config "$(CURDIR)/.tflint.hcl" --format compact

test: test-unit test-chart test-scripts ## Run all offline tests

test-unit: init ## terraform test (mocked providers) for every module and stack
	@rc=0; for d in $(ROOTS); do echo "== $$d"; $(TERRAFORM) -chdir=$$d test -no-color || rc=1; done; exit $$rc

test-chart: ## Render and assert the east-west gateway Helm chart
	tests/chart/test_eastwest_gateway.sh

test-scripts: ## Test the destroy-time ENI cleanup script against a stub aws CLI
	tests/scripts/test_cleanup_cni_enis.sh

shellcheck: ## Lint shell scripts
	$(SHELLCHECK) -x $(SCRIPTS)

security: checkov trivy secrets ## Run all security scanners

checkov: ## Checkov (Terraform, Kubernetes, GitHub Actions, secrets)
	$(CHECKOV) --config-file .checkov.yaml -d .

trivy: ## Trivy misconfiguration scan
	$(TRIVY) config --config trivy.yaml .

secrets: ## Secret scan (gitleaks if installed, else trivy)
	@if command -v gitleaks >/dev/null 2>&1; then gitleaks dir . --redact --no-banner; \
	else $(TRIVY) fs --scanners secret --exit-code 1 --quiet .; fi

ci: fmt-check validate lint test shellcheck security ## Everything CI runs

pre-commit: ## Run all pre-commit hooks on all files
	pre-commit run --all-files

##@ Deploy (needs AWS credentials)
.PHONY: preflight discover deploy plan apply kubeconfig wait-nodes e2e e2e-keep destroy lock clean
preflight: ## Read-only checks: tools, identity, Outposts
	scripts/preflight.sh

discover: ## Write starter tfvars (needs AWS_REGION and LOCAL_ZONE)
	scripts/discover.sh

deploy: preflight ## Apply all three stacks in order
	scripts/deploy.sh all

plan: ## terraform plan for one stack: make plan STACK=10-network
	@test -n "$(STACK)" || { echo "set STACK=10-network|20-clusters|30-mesh"; exit 1; }
	$(TERRAFORM) -chdir=stacks/$(STACK) init -input=false >/dev/null
	$(TERRAFORM) -chdir=stacks/$(STACK) plan -input=false

apply: ## Apply one stack and hand its outputs on: make apply STACK=20-clusters
	@test -n "$(STACK)" || { echo "set STACK=10-network|20-clusters|30-mesh"; exit 1; }
	scripts/deploy.sh $(STACK)

kubeconfig: ## Add eks-outposts and eks-localzone contexts to kubeconfig
	scripts/update-kubeconfig.sh

wait-nodes: ## Wait for Ready gateway nodes in both clusters
	scripts/wait-for-nodes.sh

e2e: ## End-to-end mesh tests against the live clusters
	validation/run-tests.sh

e2e-keep: ## End-to-end tests, leaving the sample workloads running
	validation/run-tests.sh --keep

destroy: ## Destroy everything (asks for confirmation)
	scripts/destroy.sh

lock: ## Refresh stack lock files for Linux and macOS
	@for d in $(STACKS); do echo "lock $$d"; $(TERRAFORM) -chdir=$$d init -backend=false -input=false >/dev/null || exit 1; \
	  $(TERRAFORM) -chdir=$$d providers lock $(LOCK_PLATFORMS) >/dev/null || exit 1; done

clean: ## Remove local .terraform directories and scanner output
	find . -type d -name .terraform -prune -exec rm -rf {} +
	rm -f results*.sarif
