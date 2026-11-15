# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster security group (nodes are members)."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group that admits peer mesh traffic to the nodes."
  value       = aws_security_group.nodes.id
}

output "node_role_arn" {
  description = "IAM role ARN of the worker nodes."
  value       = aws_iam_role.node.arn
}

output "autoscaling_group_name" {
  description = "Name of the worker node Auto Scaling group."
  value       = aws_autoscaling_group.nodes.name
}

output "gateway_node_selector" {
  description = "Label selector that identifies nodes running the east-west gateway."
  value       = { "edge-mesh.io/gateway" = "true" }
}
