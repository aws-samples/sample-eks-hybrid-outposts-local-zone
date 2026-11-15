# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "secret_name" {
  description = "Name of the remote secret created in the target cluster."
  value       = kubernetes_secret_v1.remote.metadata[0].name
}

output "token_secret_name" {
  description = "Name of the current reader token Secret in the source cluster (changes on every rotation)."
  value       = kubernetes_secret_v1.reader_token.metadata[0].name
}

output "token_rotates_at" {
  description = "RFC 3339 time after which the next apply replaces and revokes the reader token."
  value       = time_rotating.reader_token.rotation_rfc3339
}
