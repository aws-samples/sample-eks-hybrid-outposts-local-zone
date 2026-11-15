# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}

plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Modules are consumed only by the stacks in this repository; a README per
# module documents inputs instead of terraform-docs generated tables.
rule "terraform_standard_module_structure" {
  enabled = false
}
